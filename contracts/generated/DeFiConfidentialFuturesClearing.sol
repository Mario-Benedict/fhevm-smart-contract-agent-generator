// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiConfidentialFuturesClearing
/// @notice Futures clearinghouse where margin requirements and position sizes are encrypted.
///         Margin calls are triggered when encrypted collateral ratio drops below threshold.
contract DeFiConfidentialFuturesClearing is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct FuturesPosition {
        euint64 notionalValue;
        euint64 margin;
        euint64 unrealizedPnL;
        euint64 maintenanceMarginBps; // encrypted minimum margin ratio
        bool isLong;
        bool open;
        bool liquidated;
    }

    mapping(address => FuturesPosition) private positions;
    address[] public traders;
    euint64 private _totalOpenInterest;
    euint64 private _insuranceFund;
    euint64 private _defaultMaintenanceMarginBps;

    event PositionOpened(address indexed trader, bool isLong);
    event MarginDeposited(address indexed trader);
    event MarginCall(address indexed trader);
    event PositionLiquidated(address indexed trader);
    event PositionClosed(address indexed trader);

    constructor(
        externalEuint64 encDefaultMargin, bytes memory proof,
        externalEuint64 encInsuranceFund, bytes memory iProof
    ) Ownable(msg.sender) {
        _defaultMaintenanceMarginBps = FHE.fromExternal(encDefaultMargin, proof);
        _insuranceFund = FHE.fromExternal(encInsuranceFund, iProof);
        _totalOpenInterest = FHE.asEuint64(0);
        FHE.allowThis(_defaultMaintenanceMarginBps);
        FHE.allowThis(_insuranceFund);
        FHE.allowThis(_totalOpenInterest);
    }

    function openPosition(
        bool isLong,
        externalEuint64 encNotional, bytes calldata nProof,
        externalEuint64 encMargin, bytes calldata mProof
    ) external nonReentrant {
        require(!positions[msg.sender].open, "Position exists");
        euint64 notional = FHE.fromExternal(encNotional, nProof);
        euint64 margin = FHE.fromExternal(encMargin, mProof);
        // Check margin ratio >= maintenance
        euint64 marginRatio = FHE.div(FHE.mul(margin, 10000), notional);
        ebool adequate = FHE.ge(marginRatio, _defaultMaintenanceMarginBps);
        euint64 actualNotional = FHE.select(adequate, notional, FHE.asEuint64(0));
        positions[msg.sender] = FuturesPosition({
            notionalValue: actualNotional,
            margin: margin,
            unrealizedPnL: FHE.asEuint64(0),
            maintenanceMarginBps: _defaultMaintenanceMarginBps,
            isLong: isLong,
            open: FHE.isInitialized(adequate),
            liquidated: false
        });
        _totalOpenInterest = FHE.add(_totalOpenInterest, actualNotional);
        FHE.allowThis(positions[msg.sender].notionalValue);
        FHE.allow(positions[msg.sender].notionalValue, msg.sender);
        FHE.allowThis(positions[msg.sender].margin);
        FHE.allow(positions[msg.sender].margin, msg.sender);
        FHE.allowThis(positions[msg.sender].unrealizedPnL);
        FHE.allow(positions[msg.sender].unrealizedPnL, msg.sender);
        FHE.allowThis(positions[msg.sender].maintenanceMarginBps);
        FHE.allowThis(_totalOpenInterest);
        traders.push(msg.sender);
        emit PositionOpened(msg.sender, isLong);
    }

    function depositMargin(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(positions[msg.sender].open, "No open position");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        positions[msg.sender].margin = FHE.add(positions[msg.sender].margin, amount);
        FHE.allowThis(positions[msg.sender].margin);
        FHE.allow(positions[msg.sender].margin, msg.sender);
        emit MarginDeposited(msg.sender);
    }

    function updatePnL(address trader, externalEuint64 encPnL, bytes calldata proof) external onlyOwner {
        euint64 pnl = FHE.fromExternal(encPnL, proof);
        positions[trader].unrealizedPnL = pnl;
        FHE.allowThis(positions[trader].unrealizedPnL);
        FHE.allow(positions[trader].unrealizedPnL, trader);
    }

    function checkMarginCall(address trader) external returns (bool) {
        FuturesPosition storage p = positions[trader];
        require(p.open && !p.liquidated, "Not active");
        euint64 effectiveMargin = FHE.add(p.margin, p.unrealizedPnL);
        euint64 marginRatio = FHE.div(FHE.mul(effectiveMargin, 10000), p.notionalValue);
        ebool belowMaintenance = FHE.lt(marginRatio, p.maintenanceMarginBps);
        bool isMarginCall = FHE.isInitialized(belowMaintenance);
        if (isMarginCall) emit MarginCall(trader);
        return isMarginCall;
    }

    function liquidate(address trader) external onlyOwner nonReentrant {
        FuturesPosition storage p = positions[trader];
        require(p.open && !p.liquidated, "Not active");
        p.liquidated = true;
        p.open = false;
        _totalOpenInterest = FHE.sub(_totalOpenInterest, p.notionalValue);
        _insuranceFund = FHE.add(_insuranceFund, p.margin);
        FHE.allowThis(_totalOpenInterest);
        FHE.allowThis(_insuranceFund);
        emit PositionLiquidated(trader);
    }

    function closePosition() external nonReentrant {
        FuturesPosition storage p = positions[msg.sender];
        require(p.open && !p.liquidated, "Not active");
        p.open = false;
        _totalOpenInterest = FHE.sub(_totalOpenInterest, p.notionalValue);
        euint64 returned = FHE.add(p.margin, p.unrealizedPnL);
        FHE.allow(returned, msg.sender);
        FHE.allowThis(_totalOpenInterest);
        emit PositionClosed(msg.sender);
    }

    function allowPositionData(address viewer) external {
        FHE.allow(positions[msg.sender].notionalValue, viewer);
        FHE.allow(positions[msg.sender].margin, viewer);
        FHE.allow(positions[msg.sender].unrealizedPnL, viewer);
    }
}
