// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SilentYieldVault is ZamaEthereumConfig, ReentrancyGuard, Ownable {
    struct Position {
        euint64 encryptedStaked;
        uint256 lastUpdate;
    }

    mapping(address => Position) private positions;
    euint64 private totalEncryptedValueLocked;
    
    // Constant yield multiplier (e.g., 5% APY simulated as a flat plaintext multiplier for simplicity)
    uint256 public constant YIELD_RATE = 5; 

    event Deposited(address indexed user);
    event Withdrawn(address indexed user);

    constructor() Ownable(msg.sender) {
        totalEncryptedValueLocked = FHE.asEuint64(0);
        FHE.allowThis(totalEncryptedValueLocked);
    }

    function deposit(
        externalEuint64 extAmount,
        bytes calldata inputProof
    ) external nonReentrant {
        euint64 amount = FHE.fromExternal(extAmount, inputProof);
        FHE.allowThis(amount);

        // Compound existing yield before adding new deposit
        _compoundYield(msg.sender);

        if (!FHE.isInitialized(positions[msg.sender].encryptedStaked)) {
            positions[msg.sender].encryptedStaked = FHE.asEuint64(0);
            FHE.allowThis(positions[msg.sender].encryptedStaked);
        }

        positions[msg.sender].encryptedStaked = FHE.add(positions[msg.sender].encryptedStaked, amount);
        positions[msg.sender].lastUpdate = block.timestamp;
        FHE.allowThis(positions[msg.sender].encryptedStaked);

        totalEncryptedValueLocked = FHE.add(totalEncryptedValueLocked, amount);
        FHE.allowThis(totalEncryptedValueLocked);

        emit Deposited(msg.sender);
    }

    function _compoundYield(address user) internal {
        if (!FHE.isInitialized(positions[user].encryptedStaked)) return;
        
        uint256 timeStaked = block.timestamp - positions[user].lastUpdate;
        if (timeStaked > 0) {
            // Simulated simplified yield calculation: Staked * (Time * Rate) / Divisor
            uint256 timeMultiplier = (timeStaked * YIELD_RATE) / 10000;
            euint64 encryptedYield = FHE.mul(positions[user].encryptedStaked, uint64(timeMultiplier)); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            FHE.allowThis(encryptedYield);

            positions[user].encryptedStaked = FHE.add(positions[user].encryptedStaked, encryptedYield);
            FHE.allowThis(positions[user].encryptedStaked);
            
            totalEncryptedValueLocked = FHE.add(totalEncryptedValueLocked, encryptedYield);
            FHE.allowThis(totalEncryptedValueLocked);
        }
    }

    function withdraw(
        externalEuint64 extAmount,
        bytes calldata inputProof
    ) external nonReentrant {
        _compoundYield(msg.sender);

        euint64 amountToWithdraw = FHE.fromExternal(extAmount, inputProof);
        FHE.allowThis(amountToWithdraw);

        euint64 currentStake = positions[msg.sender].encryptedStaked;
        ebool canWithdraw = FHE.ge(currentStake, amountToWithdraw);

        positions[msg.sender].encryptedStaked = FHE.sub(currentStake, amountToWithdraw);
        positions[msg.sender].lastUpdate = block.timestamp;
        FHE.allowThis(positions[msg.sender].encryptedStaked);

        totalEncryptedValueLocked = FHE.sub(totalEncryptedValueLocked, amountToWithdraw);
        FHE.allowThis(totalEncryptedValueLocked);

        FHE.allow(amountToWithdraw, msg.sender);

        emit Withdrawn(msg.sender);
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