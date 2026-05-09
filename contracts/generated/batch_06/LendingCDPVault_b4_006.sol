// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title LendingCDPVault_b4_006 - Collateralized Debt Position vault
contract LendingCDPVault_b4_006 is ZamaEthereumConfig {
    address public owner;
    euint64 private totalCollateral;
    euint64 private totalDebt;
    mapping(address => euint64) private collateral;
    mapping(address => euint64) private debt;
    uint8 public liquidationRatioPercent; // e.g. 150 means 150% collateral required

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint8 _liqRatio) {
        owner = msg.sender;
        liquidationRatioPercent = _liqRatio;
        totalCollateral = FHE.asEuint64(0);
        totalDebt = FHE.asEuint64(0);
        FHE.allowThis(totalCollateral);
        FHE.allowThis(totalDebt);
    }

    function depositCollateral(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        collateral[msg.sender] = FHE.add(collateral[msg.sender], amount);
        totalCollateral = FHE.add(totalCollateral, amount);
        FHE.allowThis(collateral[msg.sender]);
        FHE.allowThis(totalCollateral);
    }

    function borrow(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        // max borrow = collateral * 100 / liquidationRatioPercent
        euint64 maxBorrow = FHE.mul(collateral[msg.sender], FHE.asEuint64(100));
        ebool ok = FHE.le(
            FHE.mul(FHE.add(debt[msg.sender], amount), FHE.asEuint64(uint64(liquidationRatioPercent))),
            FHE.mul(collateral[msg.sender], FHE.asEuint64(100))
        );
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        debt[msg.sender] = FHE.add(debt[msg.sender], actual);
        totalDebt = FHE.add(totalDebt, actual);
        FHE.allowThis(debt[msg.sender]);
        FHE.allowThis(totalDebt);
    }

    function repay(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, debt[msg.sender]);
        euint64 actual = FHE.select(ok, amount, debt[msg.sender]);
        debt[msg.sender] = FHE.sub(debt[msg.sender], actual);
        totalDebt = FHE.sub(totalDebt, actual);
        FHE.allowThis(debt[msg.sender]);
        FHE.allowThis(totalDebt);
    }

    function withdrawCollateral(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        euint64 remaining = FHE.sub(collateral[msg.sender], amount);
        ebool safe = FHE.ge(
            FHE.mul(remaining, FHE.asEuint64(100)),
            FHE.mul(debt[msg.sender], FHE.asEuint64(uint64(liquidationRatioPercent)))
        );
        euint64 actual = FHE.select(safe, amount, FHE.asEuint64(0));
        collateral[msg.sender] = FHE.sub(collateral[msg.sender], actual);
        totalCollateral = FHE.sub(totalCollateral, actual);
        FHE.allowThis(collateral[msg.sender]);
        FHE.allowThis(totalCollateral);
    }

    function allowPosition(address viewer) public {
        FHE.allow(collateral[msg.sender], viewer);
        FHE.allow(debt[msg.sender], viewer);
    }
}
