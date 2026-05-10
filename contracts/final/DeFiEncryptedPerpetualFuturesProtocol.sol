// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiEncryptedPerpetualFuturesProtocol
/// @notice Perpetual futures with encrypted funding rates, positions,
///         mark prices, and liquidation thresholds. Supports both
///         long and short positions with encrypted leverage.
contract DeFiEncryptedPerpetualFuturesProtocol is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum PositionSide { Long, Short }
    enum PositionStatus { Open, Liquidated, Closed }

    struct PerpMarket {
        string ticker;
        euint64 markPriceCents;         // encrypted current mark price
        euint64 indexPriceCents;        // encrypted index (spot) price
        euint32 fundingRateBps;         // encrypted 8-hour funding rate
        euint64 openInterestLong;       // encrypted long OI (notional)
        euint64 openInterestShort;      // encrypted short OI (notional)
        euint32 maxLeverage;            // max leverage (plaintext for safety)
        euint32 liquidationThresholdBps; // encrypted maintenance margin
        bool active;
    }

    struct TraderPosition {
        uint256 positionId;
        address trader;
        uint256 marketId;
        PositionSide side;
        euint64 collateralCents;        // encrypted posted margin
        euint64 notionalCents;          // encrypted position size
        euint32 leverageX10;            // encrypted leverage (e.g., 100 = 10x)
        euint64 entryPriceCents;        // encrypted entry price
        euint64 liquidationPriceCents;  // encrypted liquidation price
        euint64 unrealizedPnLCents;     // encrypted unrealized P&L
        euint64 accumulatedFundingCents; // encrypted cumulative funding
        PositionStatus status;
        uint256 openedAt;
    }

    mapping(uint256 => PerpMarket) private markets;
    mapping(uint256 => TraderPosition) private positions;
    mapping(address => uint256[]) private traderPositionIds;
    mapping(address => bool) public isLiquidator;
    mapping(address => bool) public isPriceOracle;

    uint256 public marketCount;
    uint256 public positionCount;

    euint64 private _totalCollateralLocked;
    euint64 private _totalFundingPaid;
    euint64 private _totalLiquidations;
    euint64 private _protocolRevenue;

    event MarketCreated(uint256 indexed marketId, string ticker);
    event PositionOpened(uint256 indexed positionId, address trader, PositionSide side);
    event PositionClosed(uint256 indexed positionId, address trader);
    event PositionLiquidated(uint256 indexed positionId, address liquidator);
    event FundingRateUpdated(uint256 indexed marketId);
    event PriceUpdated(uint256 indexed marketId);

    modifier onlyOracle() {
        require(isPriceOracle[msg.sender] || msg.sender == owner(), "Not oracle");
        _;
    }

    modifier onlyLiquidator() {
        require(isLiquidator[msg.sender] || msg.sender == owner(), "Not liquidator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCollateralLocked = FHE.asEuint64(0);
        _totalFundingPaid = FHE.asEuint64(0);
        _totalLiquidations = FHE.asEuint64(0);
        _protocolRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalCollateralLocked);
        FHE.allowThis(_totalFundingPaid);
        FHE.allowThis(_totalLiquidations);
        FHE.allowThis(_protocolRevenue);
        isLiquidator[msg.sender] = true;
        isPriceOracle[msg.sender] = true;
    }

    function addOracle(address ora) external onlyOwner { isPriceOracle[ora] = true; }
    function addLiquidator(address liq) external onlyOwner { isLiquidator[liq] = true; }

    function createMarket(
        string calldata ticker,
        externalEuint64 encMarkPrice, bytes calldata markProof,
        externalEuint32 encFundingRate, bytes calldata frProof,
        externalEuint32 encLiqThreshold, bytes calldata liqProof,
        uint32 maxLeverage
    ) external onlyOwner returns (uint256 marketId) {
        marketId = marketCount++;
        PerpMarket storage m = markets[marketId];
        m.ticker = ticker;
        m.markPriceCents = FHE.fromExternal(encMarkPrice, markProof);
        m.indexPriceCents = m.markPriceCents;
        m.fundingRateBps = FHE.fromExternal(encFundingRate, frProof);
        m.openInterestLong = FHE.asEuint64(0);
        m.openInterestShort = FHE.asEuint64(0);
        m.maxLeverage = FHE.asEuint32(maxLeverage);
        FHE.allowThis(m.maxLeverage);
        m.liquidationThresholdBps = FHE.fromExternal(encLiqThreshold, liqProof);
        m.active = true;
        FHE.allowThis(m.markPriceCents); FHE.allowThis(m.fundingRateBps);
        FHE.allowThis(m.openInterestLong); FHE.allowThis(m.openInterestShort);
        FHE.allowThis(m.liquidationThresholdBps);
        emit MarketCreated(marketId, ticker);
    }

    function updateMarkPrice(
        uint256 marketId,
        externalEuint64 encMarkPrice, bytes calldata markProof,
        externalEuint64 encIndexPrice, bytes calldata indexProof
    ) external onlyOracle {
        markets[marketId].markPriceCents = FHE.fromExternal(encMarkPrice, markProof);
        markets[marketId].indexPriceCents = FHE.fromExternal(encIndexPrice, indexProof);
        FHE.allowThis(markets[marketId].markPriceCents);
        FHE.allowThis(markets[marketId].indexPriceCents);
        emit PriceUpdated(marketId);
    }

    function updateFundingRate(
        uint256 marketId,
        externalEuint32 encFundingRate, bytes calldata proof
    ) external onlyOracle {
        markets[marketId].fundingRateBps = FHE.fromExternal(encFundingRate, proof);
        FHE.allowThis(markets[marketId].fundingRateBps);
        emit FundingRateUpdated(marketId);
    }

    function openPosition(
        uint256 marketId,
        PositionSide side,
        externalEuint64 encCollateral, bytes calldata collProof,
        externalEuint32 encLeverageX10, bytes calldata levProof
    ) external nonReentrant returns (uint256 positionId) {
        PerpMarket storage m = markets[marketId];
        require(m.active, "Market inactive");
        euint64 collateral = FHE.fromExternal(encCollateral, collProof);
        euint32 levX10 = FHE.fromExternal(encLeverageX10, levProof);
        ebool _safeMul25 = FHE.le(collateral, FHE.asEuint64(type(uint32).max));
        euint64 notional = FHE.mul(collateral, FHE.asEuint64(levX10));

        positionId = positionCount++;
        TraderPosition storage p = positions[positionId];
        p.positionId = positionId;
        p.trader = msg.sender;
        p.marketId = marketId;
        p.side = side;
        p.collateralCents = collateral;
        p.notionalCents = notional;
        p.leverageX10 = levX10;
        p.entryPriceCents = m.markPriceCents;
        // Liquidation price approximation (no encrypted divisor support)
        p.liquidationPriceCents = m.markPriceCents;
        p.unrealizedPnLCents = FHE.asEuint64(0);
        p.accumulatedFundingCents = FHE.asEuint64(0);
        p.status = PositionStatus.Open;
        p.openedAt = block.timestamp;

        if (side == PositionSide.Long) {
            m.openInterestLong = FHE.add(m.openInterestLong, notional);
        } else {
            m.openInterestShort = FHE.add(m.openInterestShort, notional);
        }
        _totalCollateralLocked = FHE.add(_totalCollateralLocked, collateral);

        traderPositionIds[msg.sender].push(positionId);

        FHE.allowThis(p.collateralCents); FHE.allow(p.collateralCents, msg.sender);
        FHE.allowThis(p.notionalCents); FHE.allow(p.notionalCents, msg.sender);
        FHE.allowThis(p.entryPriceCents); FHE.allow(p.entryPriceCents, msg.sender);
        FHE.allowThis(p.liquidationPriceCents); FHE.allow(p.liquidationPriceCents, msg.sender);
        FHE.allowThis(p.unrealizedPnLCents); FHE.allow(p.unrealizedPnLCents, msg.sender);
        FHE.allowThis(p.accumulatedFundingCents);
        FHE.allowThis(m.openInterestLong); FHE.allowThis(m.openInterestShort);
        FHE.allowThis(_totalCollateralLocked);

        emit PositionOpened(positionId, msg.sender, side);
    }

    function updateUnrealizedPnL(
        uint256 positionId,
        externalEuint64 encPnL, bytes calldata proof
    ) external onlyOracle {
        TraderPosition storage p = positions[positionId];
        require(p.status == PositionStatus.Open, "Not open");
        p.unrealizedPnLCents = FHE.fromExternal(encPnL, proof);
        FHE.allowThis(p.unrealizedPnLCents); FHE.allow(p.unrealizedPnLCents, p.trader);
    }

    function closePosition(uint256 positionId) external nonReentrant {
        TraderPosition storage p = positions[positionId];
        require(p.trader == msg.sender, "Not position owner");
        require(p.status == PositionStatus.Open, "Not open");
        p.status = PositionStatus.Closed;
        PerpMarket storage m = markets[p.marketId];
        if (p.side == PositionSide.Long) {
            ebool _safeSub111 = FHE.ge(m.openInterestLong, p.notionalCents);
            m.openInterestLong = FHE.select(_safeSub111, FHE.sub(m.openInterestLong, p.notionalCents), FHE.asEuint64(0));
        } else {
            ebool _safeSub112 = FHE.ge(m.openInterestShort, p.notionalCents);
            m.openInterestShort = FHE.select(_safeSub112, FHE.sub(m.openInterestShort, p.notionalCents), FHE.asEuint64(0));
        }
        ebool _safeSub113 = FHE.ge(_totalCollateralLocked, p.collateralCents);
        _totalCollateralLocked = FHE.select(_safeSub113, FHE.sub(_totalCollateralLocked, p.collateralCents), FHE.asEuint64(0));
        euint64 protocolFee = FHE.div(p.notionalCents, 1000); // 0.1% fee
        _protocolRevenue = FHE.add(_protocolRevenue, protocolFee);
        FHE.allowThis(m.openInterestLong); FHE.allowThis(m.openInterestShort);
        FHE.allowThis(_totalCollateralLocked); FHE.allowThis(_protocolRevenue);
        FHE.allow(p.unrealizedPnLCents, msg.sender);
        emit PositionClosed(positionId, msg.sender);
    }

    function liquidatePosition(uint256 positionId) external onlyLiquidator nonReentrant {
        TraderPosition storage p = positions[positionId];
        require(p.status == PositionStatus.Open, "Not open");
        p.status = PositionStatus.Liquidated;
        _totalLiquidations = FHE.add(_totalLiquidations, p.collateralCents);
        euint64 liquidatorReward = FHE.div(p.collateralCents, 20); // 5% liquidation bonus
        ebool _safeSub114 = FHE.ge(p.collateralCents, liquidatorReward);
        _protocolRevenue = FHE.add(_protocolRevenue, FHE.select(_safeSub114, FHE.sub(p.collateralCents, liquidatorReward), FHE.asEuint64(0)));
        FHE.allow(liquidatorReward, msg.sender);
        FHE.allowThis(_totalLiquidations); FHE.allowThis(_protocolRevenue);
        emit PositionLiquidated(positionId, msg.sender);
    }

    function allowProtocolStats(address viewer) external onlyOwner {
        FHE.allow(_totalCollateralLocked, viewer);
        FHE.allow(_totalFundingPaid, viewer);
        FHE.allow(_totalLiquidations, viewer);
        FHE.allow(_protocolRevenue, viewer);
    }
}
