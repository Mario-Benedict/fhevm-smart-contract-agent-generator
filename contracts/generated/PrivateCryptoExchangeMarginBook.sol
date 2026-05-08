// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCryptoExchangeMarginBook
/// @notice A crypto exchange margin trading book where position sizes,
///         leverage ratios, liquidation prices, and collateral levels
///         are encrypted per trader to prevent front-running.
contract PrivateCryptoExchangeMarginBook is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct MarginPosition {
        euint64 collateralUSD;       // posted margin
        euint64 positionSizeUSD;     // notional size
        euint32 leverageBps;         // e.g. 10000 = 10x (1000 bps = 1x)
        euint64 entryPrice;          // encrypted entry price
        euint64 liquidationPrice;    // auto-liquidation threshold
        euint32 fundingRateBps;      // encrypted perpetual funding rate
        bool isLong;
        bool active;
        uint256 openedAt;
        uint256 lastFundingPaid;
    }

    mapping(address => MarginPosition) private positions;
    mapping(address => euint64) private tradingFeeAccrued;
    address[] public traderList;

    euint64 private _totalOpenInterestLong;
    euint64 private _totalOpenInterestShort;
    euint64 private _insuranceFund;
    euint64 private _currentMarkPrice;  // updated by oracle
    address public priceOracle;
    uint256 public fundingInterval = 8 hours;

    event PositionOpened(address indexed trader, bool isLong);
    event PositionClosed(address indexed trader);
    event PositionLiquidated(address indexed trader);
    event FundingPaid(address indexed trader);
    event MarkPriceUpdated();

    constructor(address oracle, externalEuint64 encInitInsurance, bytes memory insProof)
        Ownable(msg.sender)
    {
        priceOracle = oracle;
        _insuranceFund = FHE.fromExternal(encInitInsurance, insProof);
        _totalOpenInterestLong = FHE.asEuint64(0);
        _totalOpenInterestShort = FHE.asEuint64(0);
        _currentMarkPrice = FHE.asEuint64(0);
        FHE.allowThis(_insuranceFund);
        FHE.allowThis(_totalOpenInterestLong);
        FHE.allowThis(_totalOpenInterestShort);
        FHE.allowThis(_currentMarkPrice);
    }

    function updateMarkPrice(externalEuint64 encPrice, bytes calldata proof) external {
        require(msg.sender == priceOracle || msg.sender == owner(), "Not oracle");
        _currentMarkPrice = FHE.fromExternal(encPrice, proof);
        FHE.allowThis(_currentMarkPrice);
        emit MarkPriceUpdated();
    }

    function openPosition(
        externalEuint64 encCollateral, bytes calldata collProof,
        externalEuint64 encSize, bytes calldata sizeProof,
        externalEuint32 encLeverage, bytes calldata levProof,
        externalEuint64 encLiqPrice, bytes calldata liqProof,
        bool isLong
    ) external nonReentrant {
        require(!positions[msg.sender].active, "Position already open");
        MarginPosition storage p = positions[msg.sender];
        p.collateralUSD = FHE.fromExternal(encCollateral, collProof);
        p.positionSizeUSD = FHE.fromExternal(encSize, sizeProof);
        p.leverageBps = FHE.fromExternal(encLeverage, levProof);
        p.liquidationPrice = FHE.fromExternal(encLiqPrice, liqProof);
        p.entryPrice = _currentMarkPrice;
        p.fundingRateBps = FHE.asEuint32(0);
        p.isLong = isLong;
        p.active = true;
        p.openedAt = block.timestamp;
        p.lastFundingPaid = block.timestamp;
        if (isLong) {
            _totalOpenInterestLong = FHE.add(_totalOpenInterestLong, p.positionSizeUSD);
            FHE.allowThis(_totalOpenInterestLong);
        } else {
            _totalOpenInterestShort = FHE.add(_totalOpenInterestShort, p.positionSizeUSD);
            FHE.allowThis(_totalOpenInterestShort);
        }
        if (tradingFeeAccrued[msg.sender].eq(FHE.asEuint64(0)) == FHE.eq(FHE.asEuint64(0), FHE.asEuint64(0))) {
            tradingFeeAccrued[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(tradingFeeAccrued[msg.sender]);
        }
        FHE.allowThis(p.collateralUSD);
        FHE.allow(p.collateralUSD, msg.sender);
        FHE.allowThis(p.positionSizeUSD);
        FHE.allow(p.positionSizeUSD, msg.sender);
        FHE.allowThis(p.leverageBps);
        FHE.allow(p.leverageBps, msg.sender);
        FHE.allowThis(p.liquidationPrice);
        FHE.allow(p.liquidationPrice, msg.sender);
        FHE.allowThis(p.entryPrice);
        FHE.allow(p.entryPrice, msg.sender);
        traderList.push(msg.sender);
        emit PositionOpened(msg.sender, isLong);
    }

    function closePosition(externalEuint64 encExitPrice, bytes calldata proof) external nonReentrant {
        MarginPosition storage p = positions[msg.sender];
        require(p.active, "No active position");
        euint64 exitPrice = FHE.fromExternal(encExitPrice, proof);
        // PnL = (exitPrice - entryPrice) * size / entryPrice if long
        // Simplified: compare exit vs entry
        ebool profitableExit = FHE.gt(exitPrice, p.entryPrice);
        euint64 priceDiff = FHE.select(profitableExit,
            FHE.sub(exitPrice, p.entryPrice),
            FHE.sub(p.entryPrice, exitPrice)
        );
        euint64 pnl = FHE.div(FHE.mul(priceDiff, p.positionSizeUSD), exitPrice);
        euint64 netReturn = FHE.select(profitableExit,
            FHE.add(p.collateralUSD, pnl),
            FHE.sub(p.collateralUSD, FHE.select(FHE.le(pnl, p.collateralUSD), pnl, p.collateralUSD))
        );
        if (p.isLong) {
            _totalOpenInterestLong = FHE.sub(_totalOpenInterestLong, p.positionSizeUSD);
            FHE.allowThis(_totalOpenInterestLong);
        } else {
            _totalOpenInterestShort = FHE.sub(_totalOpenInterestShort, p.positionSizeUSD);
            FHE.allowThis(_totalOpenInterestShort);
        }
        p.active = false;
        FHE.allow(netReturn, msg.sender);
        FHE.allow(pnl, msg.sender);
        FHE.allow(profitableExit, msg.sender);
        emit PositionClosed(msg.sender);
    }

    function liquidatePosition(address trader) external onlyOwner nonReentrant {
        MarginPosition storage p = positions[trader];
        require(p.active, "No position");
        // Check if mark price hit liquidation threshold
        ebool shouldLiquidate = p.isLong
            ? FHE.le(_currentMarkPrice, p.liquidationPrice)
            : FHE.ge(_currentMarkPrice, p.liquidationPrice);
        // Take collateral to insurance fund
        euint64 toInsurance = FHE.select(shouldLiquidate, p.collateralUSD, FHE.asEuint64(0));
        _insuranceFund = FHE.add(_insuranceFund, toInsurance);
        p.active = false;
        FHE.allowThis(_insuranceFund);
        FHE.allow(shouldLiquidate, trader);
        emit PositionLiquidated(trader);
    }

    function allowMyPosition(address viewer) external {
        require(positions[msg.sender].active, "No position");
        FHE.allow(positions[msg.sender].collateralUSD, viewer);
        FHE.allow(positions[msg.sender].positionSizeUSD, viewer);
        FHE.allow(positions[msg.sender].liquidationPrice, viewer);
    }

    function allowMarketMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalOpenInterestLong, viewer);
        FHE.allow(_totalOpenInterestShort, viewer);
        FHE.allow(_insuranceFund, viewer);
        FHE.allow(_currentMarkPrice, viewer);
    }
}
