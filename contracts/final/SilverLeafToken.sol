// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SilverLeafToken - Confidential ERC20 with transfer fee and mint cap
contract SilverLeafToken is ZamaEthereumConfig, Ownable {
    string public constant name = "SilverLeaf";
    string public constant symbol = "SLF";
    uint8 public constant decimals = 18;

    mapping(address => euint64) private _balances;
    euint64 private _totalSupply;
    uint64 public constant MAX_SUPPLY = 21_000_000e6;
    uint16 public feeBps = 50; // 0.5%
    address public feeRecipient;
    bool public paused;

    event Transfer(address indexed from, address indexed to);
    event Mint(address indexed to);

    constructor(address _feeRecipient) Ownable(msg.sender) {
        feeRecipient = _feeRecipient;
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
    }

    modifier notPaused() {
        require(!paused, "Paused");
        _;
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata inputProof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allowThis(_totalSupply);
        FHE.allow(_balances[to], to);
        emit Mint(to);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata inputProof) external notPaused {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        euint64 fee = FHE.div(FHE.mul(amount, FHE.asEuint64(uint64(feeBps))), 10000);
        euint64 netAmount = FHE.sub(amount, fee); // [arithmetic_overflow_underflow]
        euint64 feeScaled = FHE.mul(fee, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], amount);
        _balances[to] = FHE.add(_balances[to], netAmount);
        _balances[feeRecipient] = FHE.add(_balances[feeRecipient], fee);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allowThis(_balances[feeRecipient]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[to], to);
        FHE.allow(_balances[feeRecipient], feeRecipient);
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function setFeeBps(uint16 _feeBps) external onlyOwner {
        require(_feeBps <= 1000, "Max 10%");
        feeBps = _feeBps;
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