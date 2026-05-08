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
        externalEbool memory extFlag,
        bytes calldata inputProof
    ) external onlyOwner {
        ebool flag = FHE.fromExternal(extFlag, inputProof);
        FHE.allowThis(flag);
        blacklisted[account] = flag;
    }

    function mint(
        address to,
        externalEuint64 memory extAmount,
        bytes calldata inputProof
    ) external onlyOwner whenNotPaused {
        euint64 amount = FHE.fromExternal(extAmount, inputProof);
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
        externalEuint64 memory extAmount,
        bytes calldata inputProof
    ) external whenNotPaused {
        euint64 amount = FHE.fromExternal(extAmount, inputProof);
        FHE.allowThis(amount);

        // Validate neither sender nor recipient is blacklisted
        ebool isSenderBlacklisted = blacklisted[msg.sender];
        ebool isRecipientBlacklisted = blacklisted[to];
        ebool anyBlacklisted = FHE.or(isSenderBlacklisted, isRecipientBlacklisted);
        FHE.req(FHE.not(anyBlacklisted));

        // Validate sufficient balance
        euint64 senderBalance = balances[msg.sender];
        ebool hasSufficientFunds = FHE.ge(senderBalance, amount);
        FHE.req(hasSufficientFunds);

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
}