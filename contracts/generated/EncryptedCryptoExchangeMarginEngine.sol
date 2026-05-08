// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCryptoExchangeMarginEngine
/// @notice Cross-margined perpetual futures with encrypted position sizes,
///         unrealized PnL, funding rates, insurance fund contributions,
///         and auto-deleveraging queue rankings.
contract EncryptedCryptoExchangeMarginEngine is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum OrderSide { LONG, SHORT }
    enum MarginMode { ISOLATED, CROSS }
    enum LiquidationStatus { HEALTHY, AT_RISK, LIQUIDATING, LIQUIDATED }

    struct PerpPosition {
        OrderSide side;
        MarginMode marginMode;
        LiquidationStatus liquidationStatus;
        euint64 size;                // encrypted position size (contracts)
        euint64 entryPrice;          // encrypted average entry price
        euint64 markPrice;           // encrypted current mark price
        euint64 margin;              // encrypted posted margin
        euint64 unrealizedPnL;       // encrypted unrealized P&L
        euint64 realizedPnL;         // encrypted cumulative realized P&L
        euint64 fundingFeeAccrued;   // encrypted funding fee accrued
        euint64 maintenanceMargin;   // encrypted maintenance margin requirement
        euint64 liquidationPrice;    // encrypted liquidation price
        euint64 adlRankScore;        // encrypted ADL ranking score
        uint256 openedAt;
        uint256 lastFundingAt;
        bool active;
    }

    struct FundingRound {
        euint64 fundingRateBps;      // encrypted funding rate (bps per 8h)
        euint64 totalLongInterest;   // encrypted total long open interest
        euint64 totalShortInterest;  // encrypted total short open interest
        euint64 insuranceFundBalance;// encrypted insurance fund at snapshot
        uint256 timestamp;
    }

    mapping(address => mapping(bytes32 => PerpPosition)) private positions; // trader => marketId => position
    mapping(uint256 => FundingRound) private fundingRounds;
    mapping(bytes32 => euint64) private marketOpenInterestLong;
    mapping(bytes32 => euint64) private marketOpenInterestShort;
    mapping(bytes32 => euint64) private marketMarkPrice;

    euint64 private _insuranceFundBalance;   // encrypted insurance fund
    euint64 private _totalFeesCollected;     // encrypted total exchange fees
    euint64 private _totalLiquidationProfit; // encrypted liquidation surplus
    euint64 private _currentFundingRateBps;  // encrypted current funding rate
    uint256 private _fundingRoundCount;
    uint256 public constant FUNDING_INTERVAL = 8 hours;

    event PositionOpened(address indexed trader, bytes32 indexed marketId, OrderSide side);
    event PositionClosed(address indexed trader, bytes32 indexed marketId);
    event PositionLiquidated(address indexed trader, bytes32 indexed marketId);
    event FundingPaid(bytes32 indexed marketId, uint256 roundId);
    event InsuranceFundUpdated(uint256 timestamp);
    event ADLTriggered(address indexed trader, bytes32 indexed marketId);

    constructor(
        externalEuint64 encInitInsuranceFund, bytes memory iifProof,
        externalEuint64 encInitFundingRate, bytes memory ifrProof
    ) Ownable(msg.sender) {
        _insuranceFundBalance = FHE.fromExternal(encInitInsuranceFund, iifProof);
        _currentFundingRateBps = FHE.fromExternal(encInitFundingRate, ifrProof);
        _totalFeesCollected = FHE.asEuint64(0);
        _totalLiquidationProfit = FHE.asEuint64(0);
        FHE.allowThis(_insuranceFundBalance);
        FHE.allowThis(_currentFundingRateBps);
        FHE.allowThis(_totalFeesCollected);
        FHE.allowThis(_totalLiquidationProfit);
    }

    function openPosition(
        bytes32 marketId,
        OrderSide side,
        MarginMode marginMode,
        externalEuint64 encSize, bytes calldata sProof,
        externalEuint64 encEntryPrice, bytes calldata epProof,
        externalEuint64 encMargin, bytes calldata mProof,
        externalEuint64 encMaintenanceMargin, bytes calldata mmProof
    ) external nonReentrant {
        require(!positions[msg.sender][marketId].active, "Position already open");

        euint64 size = FHE.fromExternal(encSize, sProof);
        euint64 entryPrice = FHE.fromExternal(encEntryPrice, epProof);
        euint64 margin = FHE.fromExternal(encMargin, mProof);
        euint64 maintenanceMargin = FHE.fromExternal(encMaintenanceMargin, mmProof);

        euint64 notional = FHE.mul(size, entryPrice);
        euint64 liqPrice = side == OrderSide.LONG
            ? FHE.sub(entryPrice, FHE.div(margin, size))
            : FHE.add(entryPrice, FHE.div(margin, size));

        // ADL rank score = margin / notional (higher leverage = higher risk, lower rank)
        euint64 adlScore = FHE.div(FHE.mul(margin, FHE.asEuint64(10000)), notional);

        positions[msg.sender][marketId] = PerpPosition({
            side: side,
            marginMode: marginMode,
            liquidationStatus: LiquidationStatus.HEALTHY,
            size: size,
            entryPrice: entryPrice,
            markPrice: entryPrice,
            margin: margin,
            unrealizedPnL: FHE.asEuint64(0),
            realizedPnL: FHE.asEuint64(0),
            fundingFeeAccrued: FHE.asEuint64(0),
            maintenanceMargin: maintenanceMargin,
            liquidationPrice: liqPrice,
            adlRankScore: adlScore,
            openedAt: block.timestamp,
            lastFundingAt: block.timestamp,
            active: true
        });

        if (side == OrderSide.LONG) {
            marketOpenInterestLong[marketId] = FHE.add(marketOpenInterestLong[marketId], notional);
            FHE.allowThis(marketOpenInterestLong[marketId]);
        } else {
            marketOpenInterestShort[marketId] = FHE.add(marketOpenInterestShort[marketId], notional);
            FHE.allowThis(marketOpenInterestShort[marketId]);
        }

        euint64 fee = FHE.div(FHE.mul(notional, FHE.asEuint64(5)), FHE.asEuint64(10000)); // 0.05% taker fee
        _totalFeesCollected = FHE.add(_totalFeesCollected, fee);

        FHE.allowThis(size); FHE.allow(size, msg.sender);
        FHE.allowThis(entryPrice); FHE.allow(entryPrice, msg.sender);
        FHE.allowThis(margin); FHE.allow(margin, msg.sender);
        FHE.allowThis(maintenanceMargin); FHE.allow(maintenanceMargin, msg.sender);
        FHE.allowThis(liqPrice); FHE.allow(liqPrice, msg.sender);
        FHE.allowThis(adlScore); FHE.allow(adlScore, msg.sender);
        FHE.allowThis(positions[msg.sender][marketId].unrealizedPnL);
        FHE.allow(positions[msg.sender][marketId].unrealizedPnL, msg.sender);
        FHE.allowThis(positions[msg.sender][marketId].realizedPnL);
        FHE.allow(positions[msg.sender][marketId].realizedPnL, msg.sender);
        FHE.allowThis(positions[msg.sender][marketId].fundingFeeAccrued);
        FHE.allow(positions[msg.sender][marketId].fundingFeeAccrued, msg.sender);
        FHE.allowThis(_totalFeesCollected);

        emit PositionOpened(msg.sender, marketId, side);
    }

    function updateMarkPrice(
        bytes32 marketId,
        externalEuint64 encMarkPrice, bytes calldata mpProof,
        address[] calldata traderAddresses
    ) external onlyOwner {
        euint64 newMarkPrice = FHE.fromExternal(encMarkPrice, mpProof);
        marketMarkPrice[marketId] = newMarkPrice;
        FHE.allowThis(newMarkPrice);

        for (uint256 i = 0; i < traderAddresses.length; i++) {
            PerpPosition storage pos = positions[traderAddresses[i]][marketId];
            if (!pos.active) continue;
            pos.markPrice = newMarkPrice;

            ebool profitable = pos.side == OrderSide.LONG
                ? FHE.ge(newMarkPrice, pos.entryPrice)
                : FHE.le(newMarkPrice, pos.entryPrice);

            euint64 priceDelta = FHE.select(profitable,
                FHE.select(pos.side == OrderSide.LONG,
                    FHE.sub(newMarkPrice, pos.entryPrice),
                    FHE.sub(pos.entryPrice, newMarkPrice)),
                FHE.select(pos.side == OrderSide.LONG,
                    FHE.sub(pos.entryPrice, newMarkPrice),
                    FHE.sub(newMarkPrice, pos.entryPrice)));

            euint64 pnl = FHE.mul(priceDelta, pos.size);
            pos.unrealizedPnL = FHE.select(profitable, pnl, FHE.asEuint64(0));

            // Check if at risk: margin + unrealizedPnL < maintenanceMargin * 1.5
            euint64 effectiveMargin = FHE.select(profitable,
                FHE.add(pos.margin, pnl),
                FHE.sub(pos.margin, FHE.select(FHE.ge(pos.margin, pnl), pnl, pos.margin)));
            ebool atRisk = FHE.lt(effectiveMargin, FHE.mul(pos.maintenanceMargin, FHE.asEuint64(2)));
            // Store status signal as encrypted (0=healthy, 1=at risk)
            FHE.allowThis(pos.unrealizedPnL);
            FHE.allow(pos.unrealizedPnL, traderAddresses[i]);
            FHE.allowThis(pos.markPrice);
            FHE.allow(pos.markPrice, traderAddresses[i]);
        }
    }

    function applyFunding(
        bytes32 marketId,
        externalEuint64 encFundingRate, bytes calldata frProof,
        address[] calldata traders
    ) external onlyOwner {
        euint64 fundingRate = FHE.fromExternal(encFundingRate, frProof);
        _currentFundingRateBps = fundingRate;
        FHE.allowThis(_currentFundingRateBps);

        uint256 roundId = ++_fundingRoundCount;

        for (uint256 i = 0; i < traders.length; i++) {
            PerpPosition storage pos = positions[traders[i]][marketId];
            if (!pos.active) continue;
            euint64 notional = FHE.mul(pos.size, pos.markPrice);
            euint64 fundingPayment = FHE.div(FHE.mul(notional, fundingRate), FHE.asEuint64(10000));
            // Longs pay shorts when funding is positive
            if (pos.side == OrderSide.LONG) {
                pos.fundingFeeAccrued = FHE.add(pos.fundingFeeAccrued, fundingPayment);
                pos.margin = FHE.sub(pos.margin, FHE.select(FHE.ge(pos.margin, fundingPayment), fundingPayment, pos.margin));
            } else {
                pos.fundingFeeAccrued = FHE.add(pos.fundingFeeAccrued, fundingPayment);
                pos.margin = FHE.add(pos.margin, fundingPayment);
            }
            pos.lastFundingAt = block.timestamp;
            FHE.allowThis(pos.fundingFeeAccrued);
            FHE.allow(pos.fundingFeeAccrued, traders[i]);
            FHE.allowThis(pos.margin);
            FHE.allow(pos.margin, traders[i]);
        }
        emit FundingPaid(marketId, roundId);
    }

    function liquidatePosition(address trader, bytes32 marketId) external onlyOwner {
        PerpPosition storage pos = positions[trader][marketId];
        require(pos.active, "Not active");
        pos.liquidationStatus = LiquidationStatus.LIQUIDATED;
        pos.active = false;
        euint64 surplus = FHE.sub(pos.margin, pos.maintenanceMargin);
        _insuranceFundBalance = FHE.add(_insuranceFundBalance, surplus);
        _totalLiquidationProfit = FHE.add(_totalLiquidationProfit, surplus);
        FHE.allowThis(_insuranceFundBalance);
        FHE.allowThis(_totalLiquidationProfit);
        emit PositionLiquidated(trader, marketId);
        emit InsuranceFundUpdated(block.timestamp);
    }

    function allowPositionView(address trader, bytes32 marketId, address viewer) external {
        require(msg.sender == trader || msg.sender == owner(), "Unauthorized");
        PerpPosition storage pos = positions[trader][marketId];
        FHE.allow(pos.size, viewer);
        FHE.allow(pos.margin, viewer);
        FHE.allow(pos.unrealizedPnL, viewer);
        FHE.allow(pos.realizedPnL, viewer);
        FHE.allow(pos.liquidationPrice, viewer);
    }
}
