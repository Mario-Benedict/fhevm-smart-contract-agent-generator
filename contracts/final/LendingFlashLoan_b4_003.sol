// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title LendingFlashLoan_b4_003 - Confidential flash loan with fee tracking
contract LendingFlashLoan_b4_003 is ZamaEthereumConfig {
    address public owner;
    euint64 private lendingPool;
    euint64 private totalFeesCollected;
    uint8 public feePercentBps; // basis points
    mapping(address => euint64) private deposits;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint8 _feeBps) {
        owner = msg.sender;
        feePercentBps = _feeBps;
        lendingPool = FHE.asEuint64(0);
        totalFeesCollected = FHE.asEuint64(0);
        FHE.allowThis(lendingPool);
        FHE.allowThis(totalFeesCollected);
    }

    function deposit(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        deposits[msg.sender] = FHE.add(deposits[msg.sender], amount);
        lendingPool = FHE.add(lendingPool, amount);
        FHE.allowThis(deposits[msg.sender]);
        FHE.allowThis(lendingPool);
    }

    function withdraw(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, deposits[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        deposits[msg.sender] = FHE.sub(deposits[msg.sender], actual);
        lendingPool = FHE.sub(lendingPool, actual);
        FHE.allowThis(deposits[msg.sender]);
        FHE.allowThis(lendingPool);
    }

    function executeFlashLoan(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool sufficient = FHE.le(amount, lendingPool);
        // fee = amount * feePercentBps / 10000
        euint64 fee = FHE.mul(amount, FHE.asEuint64(uint64(feePercentBps))); // [arithmetic_overflow_underflow]
        euint64 amountScaled = FHE.mul(amount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 actualFee = FHE.select(sufficient, fee, FHE.asEuint64(0));
        totalFeesCollected = FHE.add(totalFeesCollected, actualFee);
        FHE.allowThis(totalFeesCollected);
        // In real implementation: lend, execute callback, repay+fee
    }

    function collectFees() public onlyOwner {
        deposits[owner] = FHE.add(deposits[owner], totalFeesCollected);
        totalFeesCollected = FHE.asEuint64(0);
        FHE.allowThis(deposits[owner]);
        FHE.allowThis(totalFeesCollected);
    }

    function allowDeposit(address viewer) public {
        FHE.allow(deposits[msg.sender], viewer);
    }
}
