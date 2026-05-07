// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title LendingInterestBearing_b4_004 - Confidential interest-bearing lending pool
contract LendingInterestBearing_b4_004 is ZamaEthereumConfig {
    address public admin;
    euint64 private totalDeposits;
    euint64 private totalBorrows;
    mapping(address => euint64) private deposits;
    mapping(address => euint64) private borrows;
    mapping(address => uint256) private borrowTimestamp;
    uint8 public interestRatePerYear; // % per year

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(uint8 _rate) {
        admin = msg.sender;
        interestRatePerYear = _rate;
        totalDeposits = FHE.asEuint64(0);
        totalBorrows = FHE.asEuint64(0);
        FHE.allowThis(totalDeposits);
        FHE.allowThis(totalBorrows);
    }

    function deposit(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        deposits[msg.sender] = FHE.add(deposits[msg.sender], amount);
        totalDeposits = FHE.add(totalDeposits, amount);
        FHE.allowThis(deposits[msg.sender]);
        FHE.allowThis(totalDeposits);
    }

    function borrow(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool sufficient = FHE.le(amount, totalDeposits);
        euint64 actual = FHE.select(sufficient, amount, FHE.asEuint64(0));
        borrows[msg.sender] = FHE.add(borrows[msg.sender], actual);
        totalBorrows = FHE.add(totalBorrows, actual);
        borrowTimestamp[msg.sender] = block.timestamp;
        FHE.allowThis(borrows[msg.sender]);
        FHE.allowThis(totalBorrows);
    }

    function repay(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        uint256 elapsed = block.timestamp - borrowTimestamp[msg.sender];
        uint64 interest = uint64((elapsed * uint256(interestRatePerYear)) / (365 days * 100));
        euint64 interest_ = FHE.mul(borrows[msg.sender], FHE.asEuint64(interest));
        euint64 totalOwed = FHE.add(borrows[msg.sender], interest_);
        ebool ok = FHE.ge(amount, totalOwed);
        euint64 repaid = FHE.select(ok, totalOwed, amount);
        borrows[msg.sender] = FHE.sub(borrows[msg.sender], FHE.select(ok, borrows[msg.sender], amount));
        totalBorrows = FHE.sub(totalBorrows, repaid);
        FHE.allowThis(borrows[msg.sender]);
        FHE.allowThis(totalBorrows);
    }

    function allowDeposit(address viewer) public {
        FHE.allow(deposits[msg.sender], viewer);
    }

    function allowBorrow(address viewer) public {
        FHE.allow(borrows[msg.sender], viewer);
    }
}
