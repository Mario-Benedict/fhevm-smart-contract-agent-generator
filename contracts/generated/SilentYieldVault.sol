// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SilentYieldVault is ZamaEthereumConfig, ReentrancyGuard, Ownable {
    struct Position {
        euint128 encryptedStaked;
        uint256 lastUpdate;
    }

    mapping(address => Position) private positions;
    euint128 private totalEncryptedValueLocked;
    
    // Constant yield multiplier (e.g., 5% APY simulated as a flat plaintext multiplier for simplicity)
    uint256 public constant YIELD_RATE = 5; 

    event Deposited(address indexed user);
    event Withdrawn(address indexed user);

    constructor() Ownable(msg.sender) {
        totalEncryptedValueLocked = FHE.asEuint128(0);
        FHE.allowThis(totalEncryptedValueLocked);
    }

    function deposit(
        externalEuint128 extAmount,
        bytes calldata inputProof
    ) external nonReentrant {
        euint128 amount = FHE.fromExternal(extAmount, inputProof);
        FHE.allowThis(amount);

        // Compound existing yield before adding new deposit
        _compoundYield(msg.sender);

        if (!FHE.isInitialized(positions[msg.sender].encryptedStaked)) {
            positions[msg.sender].encryptedStaked = FHE.asEuint128(0);
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
            euint128 encryptedYield = FHE.mul(positions[user].encryptedStaked, FHE.asEuint128(timeMultiplier));
            FHE.allowThis(encryptedYield);

            positions[user].encryptedStaked = FHE.add(positions[user].encryptedStaked, encryptedYield);
            FHE.allowThis(positions[user].encryptedStaked);
            
            totalEncryptedValueLocked = FHE.add(totalEncryptedValueLocked, encryptedYield);
            FHE.allowThis(totalEncryptedValueLocked);
        }
    }

    function withdraw(
        externalEuint128 extAmount,
        bytes calldata inputProof
    ) external nonReentrant {
        _compoundYield(msg.sender);

        euint128 amountToWithdraw = FHE.fromExternal(extAmount, inputProof);
        FHE.allowThis(amountToWithdraw);

        euint128 currentStake = positions[msg.sender].encryptedStaked;
        ebool canWithdraw = FHE.ge(currentStake, amountToWithdraw);

        positions[msg.sender].encryptedStaked = FHE.sub(currentStake, amountToWithdraw);
        positions[msg.sender].lastUpdate = block.timestamp;
        FHE.allowThis(positions[msg.sender].encryptedStaked);

        totalEncryptedValueLocked = FHE.sub(totalEncryptedValueLocked, amountToWithdraw);
        FHE.allowThis(totalEncryptedValueLocked);

        FHE.allow(amountToWithdraw, msg.sender);

        emit Withdrawn(msg.sender);
    }
}