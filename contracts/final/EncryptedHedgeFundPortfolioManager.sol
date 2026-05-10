// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedHedgeFundPortfolioManager
/// @notice Multi-strategy hedge fund NAV tracking: encrypted portfolio positions,
///         confidential performance fees, and private high-water mark calculations.
///         Implements long/short equity, macro, and arbitrage strategies.
contract EncryptedHedgeFundPortfolioManager is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum Strategy { LONG_SHORT_EQUITY, GLOBAL_MACRO, STAT_ARB, EVENT_DRIVEN, FIXED_INCOME_ARB }
    enum ShareClass { CLASS_A, CLASS_B, CLASS_C } // different fee structures

    struct FundStats {
        euint64 totalAUM;                    // encrypted total assets under management
        euint64 netAssetValuePerShare;       // encrypted NAV per share
        euint64 highWaterMarkPerShare;       // encrypted high-water mark
        euint64 totalPerformanceFeeCollected;// encrypted cumulative perf fees
        euint64 totalManagementFeeCollected; // encrypted cumulative mgmt fees
        euint64 totalLong;                   // encrypted long book value
        euint64 totalShort;                  // encrypted short book value
        euint64 cashAndEquivalents;          // encrypted cash position
        euint64 leverage;                    // encrypted gross leverage (bps)
    }

    struct InvestorAccount {
        ShareClass shareClass;
        euint64 sharesHeld;                  // encrypted shares held
        euint64 totalInvested;               // encrypted total capital invested
        euint64 unrealizedGainLoss;          // encrypted unrealized P&L
        euint64 realizedGainLoss;            // encrypted realized P&L
        euint64 lastNAVPerShare;             // encrypted NAV at last subscription
        euint64 highWaterMarkOwn;            // encrypted personal high-water mark
        euint64 pendingPerformanceFee;       // encrypted accrued performance fee
        uint256 lockupExpiry;
        bool active;
        bool gated;
    }

    struct Position {
        bytes32 assetId;
        Strategy strategy;
        bool isLong;
        euint64 notionalValueUSD;            // encrypted position notional
        euint64 entryPriceUSD;               // encrypted average entry price
        euint64 currentPriceUSD;             // encrypted current mark price
        euint64 unrealizedPnLUSD;            // encrypted unrealized P&L
        euint64 marginRequirementUSD;        // encrypted required margin
        bool active;
    }

    FundStats private fundStats;
    mapping(address => InvestorAccount) private investors;
    mapping(bytes32 => Position) private positions;
    mapping(uint8 => euint64) private performanceFeeRateByClass;  // per share class
    mapping(uint8 => euint64) private managementFeeRateByClass;
    mapping(address => bool) public isPortfolioManager;
    mapping(address => bool) public isApprovedInvestor;

    euint64 private _hurdleRateBps;          // encrypted hurdle rate

    event InvestorSubscribed(address indexed investor, ShareClass sc);
    event RedemptionProcessed(address indexed investor);
    event PositionOpened(bytes32 indexed assetId, Strategy strategy, bool isLong);
    event PositionClosed(bytes32 indexed assetId);
    event NAVUpdated(uint256 timestamp);
    event PerformanceFeeCharged(address indexed investor);

    constructor(
        externalEuint64 encInitialNAV, bytes memory navProof,
        externalEuint64 encHurdleRate, bytes memory hrProof
    ) Ownable(msg.sender) {
        fundStats.netAssetValuePerShare = FHE.fromExternal(encInitialNAV, navProof);
        fundStats.highWaterMarkPerShare = fundStats.netAssetValuePerShare;
        _hurdleRateBps = FHE.fromExternal(encHurdleRate, hrProof);
        fundStats.totalAUM = FHE.asEuint64(0);
        fundStats.totalPerformanceFeeCollected = FHE.asEuint64(0);
        fundStats.totalManagementFeeCollected = FHE.asEuint64(0);
        fundStats.totalLong = FHE.asEuint64(0);
        fundStats.totalShort = FHE.asEuint64(0);
        fundStats.cashAndEquivalents = FHE.asEuint64(0);
        fundStats.leverage = FHE.asEuint64(10000); // 1x initially
        FHE.allowThis(fundStats.totalAUM);
        FHE.allowThis(fundStats.netAssetValuePerShare);
        FHE.allowThis(fundStats.highWaterMarkPerShare);
        FHE.allowThis(fundStats.totalPerformanceFeeCollected);
        FHE.allowThis(fundStats.totalManagementFeeCollected);
        FHE.allowThis(fundStats.totalLong);
        FHE.allowThis(fundStats.totalShort);
        FHE.allowThis(fundStats.cashAndEquivalents);
        FHE.allowThis(fundStats.leverage);
        FHE.allowThis(_hurdleRateBps);
        isPortfolioManager[msg.sender] = true;
        isApprovedInvestor[msg.sender] = true;
        // Set default fee structures per share class
        for (uint8 i = 0; i < 3; i++) {
            performanceFeeRateByClass[i] = FHE.asEuint64(2000); // 20% performance fee
            managementFeeRateByClass[i] = FHE.asEuint64(200);   // 2% management fee
            FHE.allowThis(performanceFeeRateByClass[i]);
            FHE.allowThis(managementFeeRateByClass[i]);
        }
    }

    modifier onlyPortfolioManager() { require(isPortfolioManager[msg.sender], "Not PM"); _; }

    function subscribe(
        ShareClass sc,
        externalEuint64 encInvestmentUSD, bytes calldata iProof,
        uint256 lockupPeriodDays
    ) external nonReentrant {
        require(isApprovedInvestor[msg.sender], "Not approved");
        euint64 investment = FHE.fromExternal(encInvestmentUSD, iProof);
        // Calculate shares to issue at current NAV
        euint64 sharesToIssue = FHE.mul(investment, FHE.asEuint64(uint64(1e6))); // simplified: NAV divisor omitted
        InvestorAccount storage inv = investors[msg.sender];
        inv.shareClass = sc;
        inv.sharesHeld = FHE.add(inv.sharesHeld, sharesToIssue);
        inv.totalInvested = FHE.add(inv.totalInvested, investment);
        inv.lastNAVPerShare = fundStats.netAssetValuePerShare;
        inv.highWaterMarkOwn = fundStats.netAssetValuePerShare;
        inv.unrealizedGainLoss = FHE.asEuint64(0);
        inv.realizedGainLoss = FHE.asEuint64(0);
        inv.pendingPerformanceFee = FHE.asEuint64(0);
        inv.lockupExpiry = block.timestamp + (lockupPeriodDays * 1 days);
        inv.active = true;
        fundStats.totalAUM = FHE.add(fundStats.totalAUM, investment);
        fundStats.cashAndEquivalents = FHE.add(fundStats.cashAndEquivalents, investment);
        FHE.allowThis(inv.sharesHeld);
        FHE.allow(inv.sharesHeld, msg.sender);
        FHE.allowThis(inv.totalInvested);
        FHE.allow(inv.totalInvested, msg.sender);
        FHE.allowThis(inv.lastNAVPerShare);
        FHE.allow(inv.lastNAVPerShare, msg.sender);
        FHE.allowThis(inv.highWaterMarkOwn);
        FHE.allowThis(inv.unrealizedGainLoss);
        FHE.allow(inv.unrealizedGainLoss, msg.sender);
        FHE.allowThis(inv.realizedGainLoss);
        FHE.allow(inv.realizedGainLoss, msg.sender);
        FHE.allowThis(inv.pendingPerformanceFee);
        FHE.allow(inv.pendingPerformanceFee, msg.sender);
        FHE.allowThis(fundStats.totalAUM);
        FHE.allowThis(fundStats.cashAndEquivalents);
        emit InvestorSubscribed(msg.sender, sc);
    }

    function openPosition(
        bytes32 assetId,
        Strategy strategy,
        bool isLong,
        externalEuint64 encNotional, bytes calldata nProof,
        externalEuint64 encEntryPrice, bytes calldata epProof,
        externalEuint64 encMarginReq, bytes calldata mrProof
    ) external onlyPortfolioManager {
        euint64 notional = FHE.fromExternal(encNotional, nProof);
        euint64 entryPrice = FHE.fromExternal(encEntryPrice, epProof);
        euint64 marginReq = FHE.fromExternal(encMarginReq, mrProof);
        positions[assetId].assetId = assetId;
        positions[assetId].strategy = strategy;
        positions[assetId].isLong = isLong;
        positions[assetId].notionalValueUSD = notional;
        positions[assetId].entryPriceUSD = entryPrice;
        positions[assetId].currentPriceUSD = entryPrice;
        positions[assetId].unrealizedPnLUSD = FHE.asEuint64(0);
        positions[assetId].marginRequirementUSD = marginReq;
        positions[assetId].active = true;
        if (isLong) {
            fundStats.totalLong = FHE.add(fundStats.totalLong, notional);
            FHE.allowThis(fundStats.totalLong);
        } else {
            fundStats.totalShort = FHE.add(fundStats.totalShort, notional);
            FHE.allowThis(fundStats.totalShort);
        }
        fundStats.cashAndEquivalents = FHE.sub(fundStats.cashAndEquivalents, marginReq);
        FHE.allowThis(positions[assetId].notionalValueUSD);
        FHE.allowThis(positions[assetId].entryPriceUSD);
        FHE.allowThis(positions[assetId].currentPriceUSD);
        FHE.allowThis(positions[assetId].unrealizedPnLUSD);
        FHE.allowThis(positions[assetId].marginRequirementUSD);
        FHE.allowThis(fundStats.cashAndEquivalents);
        emit PositionOpened(assetId, strategy, isLong);
    }

    function updatePositionPrice(
        bytes32 assetId,
        externalEuint64 encCurrentPrice, bytes calldata cpProof
    ) external onlyPortfolioManager {
        Position storage p = positions[assetId];
        require(p.active, "Position not active");
        euint64 currentPrice = FHE.fromExternal(encCurrentPrice, cpProof);
        p.currentPriceUSD = currentPrice;
        ebool profitable = p.isLong ?
            FHE.ge(currentPrice, p.entryPriceUSD) :
            FHE.le(currentPrice, p.entryPriceUSD);
        euint64 longDiff = FHE.select(profitable, FHE.sub(currentPrice, p.entryPriceUSD), FHE.sub(p.entryPriceUSD, currentPrice));
        euint64 shortDiff = FHE.select(profitable, FHE.sub(p.entryPriceUSD, currentPrice), FHE.sub(currentPrice, p.entryPriceUSD));
        euint64 priceDiff = p.isLong ? longDiff : shortDiff;
        euint64 pnl = FHE.mul(priceDiff, p.notionalValueUSD); // simplified: entryPrice divisor omitted
        p.unrealizedPnLUSD = FHE.select(profitable, pnl, FHE.asEuint64(0));
        FHE.allowThis(p.currentPriceUSD);
        FHE.allowThis(p.unrealizedPnLUSD);
    }

    function updateNAV(externalEuint64 encNewNAV, bytes calldata navProof) external onlyPortfolioManager {
        euint64 newNAV = FHE.fromExternal(encNewNAV, navProof);
        fundStats.netAssetValuePerShare = newNAV;
        // Update high-water mark if new NAV exceeds it
        ebool newHWM = FHE.gt(newNAV, fundStats.highWaterMarkPerShare);
        fundStats.highWaterMarkPerShare = FHE.select(newHWM, newNAV, fundStats.highWaterMarkPerShare);
        FHE.allowThis(fundStats.netAssetValuePerShare);
        FHE.allowThis(fundStats.highWaterMarkPerShare);
        emit NAVUpdated(block.timestamp);
    }

    function accruePerformanceFee(address investor) external onlyPortfolioManager {
        InvestorAccount storage inv = investors[investor];
        require(inv.active, "Not active");
        // Performance fee = 20% of gains above high-water mark
        ebool aboveHWM = FHE.gt(fundStats.netAssetValuePerShare, inv.highWaterMarkOwn);
        euint64 gainPerShare = FHE.select(aboveHWM,
            FHE.sub(fundStats.netAssetValuePerShare, inv.highWaterMarkOwn),
            FHE.asEuint64(0));
        euint64 totalGain = FHE.mul(gainPerShare, inv.sharesHeld);
        euint64 perfFee = FHE.div(FHE.mul(totalGain, performanceFeeRateByClass[uint8(inv.shareClass)]), 10000);
        inv.pendingPerformanceFee = FHE.add(inv.pendingPerformanceFee, perfFee);
        inv.highWaterMarkOwn = FHE.select(aboveHWM, fundStats.netAssetValuePerShare, inv.highWaterMarkOwn);
        fundStats.totalPerformanceFeeCollected = FHE.add(fundStats.totalPerformanceFeeCollected, perfFee);
        FHE.allowThis(inv.pendingPerformanceFee);
        FHE.allow(inv.pendingPerformanceFee, investor);
        FHE.allowThis(inv.highWaterMarkOwn);
        FHE.allowThis(fundStats.totalPerformanceFeeCollected);
        emit PerformanceFeeCharged(investor);
    }

    function redeem(externalEuint64 encShares, bytes calldata sProof) external nonReentrant {
        InvestorAccount storage inv = investors[msg.sender];
        require(inv.active && !inv.gated, "Cannot redeem");
        require(block.timestamp >= inv.lockupExpiry, "In lockup");
        euint64 shares = FHE.fromExternal(encShares, sProof);
        ebool hasShares = FHE.ge(inv.sharesHeld, shares);
        euint64 actualShares = FHE.select(hasShares, shares, inv.sharesHeld);
        euint64 redemptionValue = FHE.div(FHE.mul(actualShares, fundStats.netAssetValuePerShare), uint64(1e6));
        euint64 netAfterFees = FHE.sub(redemptionValue, inv.pendingPerformanceFee);
        inv.sharesHeld = FHE.sub(inv.sharesHeld, actualShares);
        inv.pendingPerformanceFee = FHE.asEuint64(0);
        fundStats.totalAUM = FHE.sub(fundStats.totalAUM, redemptionValue);
        FHE.allowThis(inv.sharesHeld);
        FHE.allow(inv.sharesHeld, msg.sender);
        FHE.allowThis(inv.pendingPerformanceFee);
        FHE.allow(inv.pendingPerformanceFee, msg.sender);
        FHE.allowThis(fundStats.totalAUM);
        FHE.allow(netAfterFees, msg.sender); // [acl_misconfig]
        FHE.allow(_hurdleRateBps, msg.sender); // [acl_misconfig]
        emit RedemptionProcessed(msg.sender);
    }

    function gateInvestor(address investor) external onlyPortfolioManager { investors[investor].gated = true; }
    function ungateInvestor(address investor) external onlyPortfolioManager { investors[investor].gated = false; }
    function approveInvestor(address i) external onlyOwner { isApprovedInvestor[i] = true; }
    function addPortfolioManager(address pm) external onlyOwner { isPortfolioManager[pm] = true; }

    function allowFundStats(address lp) external onlyPortfolioManager {
        FHE.allow(fundStats.totalAUM, lp);
        FHE.allow(fundStats.netAssetValuePerShare, lp);
        FHE.allow(fundStats.highWaterMarkPerShare, lp);
    }
}
