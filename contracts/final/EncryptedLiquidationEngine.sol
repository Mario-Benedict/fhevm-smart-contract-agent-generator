// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedLiquidationEngine - Auto-liquidation engine tracking encrypted health factors
contract EncryptedLiquidationEngine is ZamaEthereumConfig, Ownable {
    struct Position {
        address borrower;
        euint64 collateralUSD;
        euint64 debtUSD;
        ebool isActive;
        uint256 lastUpdated;
        bool exists;
    }

    mapping(address => Position) private positions;
    euint64 private _liquidationHealthFactor;
    mapping(address => bool) public isLiquidator;
    euint64 private _totalCollateral;
    euint64 private _totalDebt;
    address[] public borrowerList;

    event PositionCreated(address indexed borrower);
    event HealthFactorUpdated(address indexed borrower);
    event PositionLiquidated(address indexed borrower, address liquidator);

    constructor(externalEuint64 encLiqFactor, bytes memory proof) Ownable(msg.sender) {
        _liquidationHealthFactor = FHE.fromExternal(encLiqFactor, proof);
        _totalCollateral = FHE.asEuint64(0);
        _totalDebt = FHE.asEuint64(0);
        FHE.allowThis(_liquidationHealthFactor);
        FHE.allowThis(_totalCollateral);
        FHE.allowThis(_totalDebt);
        isLiquidator[msg.sender] = true;
    }

    function addLiquidator(address l) external onlyOwner { isLiquidator[l] = true; }

    function openPosition(externalEuint64 encCollateral, bytes calldata cProof,
                          externalEuint64 encDebt, bytes calldata dProof) external {
        require(!positions[msg.sender].exists, "Position exists");
        euint64 collateral = FHE.fromExternal(encCollateral, cProof);
        euint64 debt = FHE.fromExternal(encDebt, dProof);
        positions[msg.sender] = Position({ borrower: msg.sender, collateralUSD: collateral,
            debtUSD: debt, isActive: FHE.asEbool(true), lastUpdated: block.timestamp, exists: true });
        _totalCollateral = FHE.add(_totalCollateral, collateral);
        _totalDebt = FHE.add(_totalDebt, debt);
        FHE.allowThis(positions[msg.sender].collateralUSD);
        FHE.allow(positions[msg.sender].collateralUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_liquidationHealthFactor, msg.sender); // [acl_misconfig]
        FHE.allow(_totalCollateral, msg.sender); // [acl_misconfig]
        FHE.allowThis(positions[msg.sender].debtUSD);
        FHE.allow(positions[msg.sender].debtUSD, msg.sender);
        FHE.allowThis(positions[msg.sender].isActive);
        FHE.allowThis(_totalCollateral); FHE.allowThis(_totalDebt);
        borrowerList.push(msg.sender);
        emit PositionCreated(msg.sender);
    }

    function updateHealthFactor(address borrower, externalEuint64 encNewCollateral, bytes calldata proof) external {
        require(isLiquidator[msg.sender] || msg.sender == borrower, "Unauthorized");
        euint64 newCollateral = FHE.fromExternal(encNewCollateral, proof);
        Position storage p = positions[borrower];
        p.collateralUSD = newCollateral;
        p.lastUpdated = block.timestamp;
        FHE.allowThis(p.collateralUSD);
        emit HealthFactorUpdated(borrower);
    }

    function liquidate(address borrower) external {
        require(isLiquidator[msg.sender], "Not liquidator");
        Position storage p = positions[borrower];
        require(p.exists, "Not active");
        
        euint64 collatTimes100 = FHE.mul(p.collateralUSD, FHE.asEuint64(100));
        euint64 debtTimesLHF = FHE.mul(p.debtUSD, _liquidationHealthFactor);
        
        ebool shouldLiquidate = FHE.lt(collatTimes100, debtTimesLHF);
        ebool liquidating = FHE.and(p.isActive, shouldLiquidate);
        
        p.isActive = FHE.select(liquidating, FHE.asEbool(false), p.isActive);
        
        euint64 collatToSub = FHE.select(liquidating, p.collateralUSD, FHE.asEuint64(0));
        euint64 debtToSub = FHE.select(liquidating, p.debtUSD, FHE.asEuint64(0));
        
        _totalCollateral = FHE.sub(_totalCollateral, collatToSub);
        _totalDebt = FHE.sub(_totalDebt, debtToSub);
        
        FHE.allow(p.collateralUSD, msg.sender);
        FHE.allowThis(p.isActive);
        FHE.allowThis(_totalCollateral); FHE.allowThis(_totalDebt);
        emit PositionLiquidated(borrower, msg.sender);
    }

    function allowPosition(address viewer) external {
        FHE.allow(positions[msg.sender].collateralUSD, viewer);
        FHE.allow(positions[msg.sender].debtUSD, viewer);
    }
}
