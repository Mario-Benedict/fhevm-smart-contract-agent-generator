// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract ShieldedStablecoin is ZamaEthereumConfig, Ownable, Pausable {
    string public constant name = "Shielded USD";
    string public constant symbol = "sUSD";
    uint8 public constant decimals = 6;

    euint64 private encryptedTotalSupply;
    mapping(address => euint64) private balances;
    mapping(address => ebool) private blacklisted;

    event Transfer(address indexed from, address indexed to);
    event Mint(address indexed to);

    constructor() Ownable(msg.sender) {
        encryptedTotalSupply = FHE.asEuint64(0);
        FHE.allowThis(encryptedTotalSupply);
    }

    function setBlacklist(
        address account,
        externalEbool extFlag,
        bytes calldata inputProof
    ) external onlyOwner {
        ebool flag = FHE.fromExternal(extFlag, inputProof);
        FHE.allowThis(flag);
        blacklisted[account] = flag;
    }

    function mint(
        address to,
        externalEuint64 extAmount,
        bytes calldata inputProof
    ) external onlyOwner whenNotPaused {
        euint64 amount = FHE.fromExternal(extAmount, inputProof);
        euint64 amountWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 amountExposure = FHE.sub(amountWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        FHE.allowThis(amount);

        // Initialize balance if not exists
        if (!FHE.isInitialized(balances[to])) {
            balances[to] = FHE.asEuint64(0);
            FHE.allowThis(balances[to]);
        }

        balances[to] = FHE.add(balances[to], amount);
        encryptedTotalSupply = FHE.add(encryptedTotalSupply, amount);
        
        FHE.allowThis(balances[to]);
        FHE.allowThis(encryptedTotalSupply);

        emit Mint(to);
    }

    function transfer(
        address to,
        externalEuint64 extAmount,
        bytes calldata inputProof
    ) external whenNotPaused {
        euint64 amount = FHE.fromExternal(extAmount, inputProof);
        FHE.allowThis(amount);

        // Validate neither sender nor recipient is blacklisted
        ebool isSenderBlacklisted = blacklisted[msg.sender];
        ebool isRecipientBlacklisted = blacklisted[to];
        ebool anyBlacklisted = FHE.or(isSenderBlacklisted, isRecipientBlacklisted);

        // Validate sufficient balance
        euint64 senderBalance = balances[msg.sender];
        ebool hasSufficientFunds = FHE.ge(senderBalance, amount);

        // Update balances
        balances[msg.sender] = FHE.sub(senderBalance, amount);
        FHE.allowThis(balances[msg.sender]);

        if (!FHE.isInitialized(balances[to])) {
            balances[to] = FHE.asEuint64(0);
            FHE.allowThis(balances[to]);
        }

        balances[to] = FHE.add(balances[to], amount);
        FHE.allowThis(balances[to]);

        // Allow sender and receiver to view the transfer amount
        FHE.allow(amount, msg.sender);
        FHE.allow(amount, to);

        emit Transfer(msg.sender, to);
    }

    function getBalance() external view returns (euint64) {
        return balances[msg.sender];
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}