// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCollateralVault - Encrypted collateral management for confidential borrowing
contract PrivateCollateralVault is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Position {
        euint64 collateral;
        euint64 debt;
        uint256 lastUpdated;
        bool active;
    }

    mapping(address => Position) public positions;
    euint64 private totalCollateral;
    euint64 private totalDebt;
    uint16 public collateralRatioBps = 15000; // 150%
    uint16 public liquidationPenaltyBps = 1000; // 10%

    event PositionOpened(address indexed user);
    event CollateralDeposited(address indexed user);
    event DebtIssued(address indexed user);
    event DebtRepaid(address indexed user);
    event PositionLiquidated(address indexed user, address indexed liquidator);

    constructor() Ownable(msg.sender) {
        totalCollateral = FHE.asEuint64(0);
        totalDebt = FHE.asEuint64(0);
        FHE.allowThis(totalCollateral);
        FHE.allowThis(totalDebt);
    }

    function openPosition() external {
        require(!positions[msg.sender].active, "Already active");
        positions[msg.sender].collateral = FHE.asEuint64(0);
        positions[msg.sender].debt = FHE.asEuint64(0);
        positions[msg.sender].active = true;
        positions[msg.sender].lastUpdated = block.timestamp;
        FHE.allowThis(positions[msg.sender].collateral);
        FHE.allowThis(positions[msg.sender].debt);
        FHE.allow(positions[msg.sender].collateral, msg.sender);
        FHE.allow(positions[msg.sender].debt, msg.sender);
        emit PositionOpened(msg.sender);
    }

    function depositCollateral(externalEuint64 calldata encAmount, bytes calldata inputProof) external nonReentrant {
        require(positions[msg.sender].active, "No position");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        positions[msg.sender].collateral = FHE.add(positions[msg.sender].collateral, amount);
        totalCollateral = FHE.add(totalCollateral, amount);
        FHE.allowThis(positions[msg.sender].collateral);
        FHE.allowThis(totalCollateral);
        FHE.allow(positions[msg.sender].collateral, msg.sender);
        emit CollateralDeposited(msg.sender);
    }

    function issueDebt(externalEuint64 calldata encAmount, bytes calldata inputProof) external nonReentrant {
        require(positions[msg.sender].active, "No position");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        euint64 maxDebt = FHE.div(FHE.mul(positions[msg.sender].collateral, FHE.asEuint64(10000)), FHE.asEuint64(collateralRatioBps));
        ebool safe = FHE.le(FHE.add(positions[msg.sender].debt, amount), maxDebt);
        euint64 safeAmount = FHE.select(safe, amount, FHE.asEuint64(0));
        positions[msg.sender].debt = FHE.add(positions[msg.sender].debt, safeAmount);
        totalDebt = FHE.add(totalDebt, safeAmount);
        FHE.allowThis(positions[msg.sender].debt);
        FHE.allowThis(totalDebt);
        FHE.allow(positions[msg.sender].debt, msg.sender);
        FHE.allowTransient(safeAmount, msg.sender);
        emit DebtIssued(msg.sender);
    }

    function repayDebt(externalEuint64 calldata encAmount, bytes calldata inputProof) external nonReentrant {
        require(positions[msg.sender].active, "No position");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        positions[msg.sender].debt = FHE.sub(positions[msg.sender].debt, amount);
        totalDebt = FHE.sub(totalDebt, amount);
        FHE.allowThis(positions[msg.sender].debt);
        FHE.allowThis(totalDebt);
        FHE.allow(positions[msg.sender].debt, msg.sender);
        emit DebtRepaid(msg.sender);
    }

    function liquidate(address user) external nonReentrant {
        Position storage p = positions[user];
        require(p.active, "No position");
        euint64 maxDebt = FHE.div(FHE.mul(p.collateral, FHE.asEuint64(10000)), FHE.asEuint64(collateralRatioBps));
        ebool undercollateralized = FHE.gt(p.debt, maxDebt);
        euint64 penalty = FHE.select(undercollateralized,
            FHE.div(FHE.mul(p.collateral, FHE.asEuint64(liquidationPenaltyBps)), FHE.asEuint64(10000)),
            FHE.asEuint64(0)
        );
        p.collateral = FHE.sub(p.collateral, penalty);
        FHE.allowThis(p.collateral);
        FHE.allowTransient(penalty, msg.sender);
        emit PositionLiquidated(user, msg.sender);
    }
}
