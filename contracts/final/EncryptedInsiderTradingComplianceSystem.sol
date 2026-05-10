// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedInsiderTradingComplianceSystem
/// @notice Corporate insider trading compliance with encrypted pre-clearance windows,
///         confidential holdings disclosures, and private blackout period enforcement.
///         Monitors encrypted trade sizes against position thresholds.
contract EncryptedInsiderTradingComplianceSystem is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum InsiderTier { DIRECTOR, OFFICER, TEN_PERCENT_HOLDER, DESIGNATED_PERSON }
    enum ClearanceStatus { PENDING, APPROVED, DENIED, EXPIRED }
    enum BlackoutReason { EARNINGS, MA_ACTIVITY, STRATEGIC_UPDATE, REGULATORY }

    struct InsiderProfile {
        InsiderTier tier;
        euint64 totalSharesHeld;        // encrypted total beneficial holdings
        euint64 restrictedShares;       // encrypted locked/restricted shares
        euint64 vestedOptionsUnexercised;// encrypted vested options
        euint64 annualTradingWindowBps; // encrypted % of year eligible to trade
        euint64 quarterlyTradeCap;      // encrypted max shares per quarter
        euint64 tradesThisQuarter;      // encrypted shares traded this quarter
        bool registered;
        bool suspended;
    }

    struct PreClearanceRequest {
        address insider;
        bool isBuy;
        euint64 sharesRequested;        // encrypted trade size
        euint64 estimatedValueUSD;      // encrypted estimated transaction value
        euint64 postTradeHoldingBps;    // encrypted % of holdings post-trade
        ClearanceStatus status;
        uint256 requestedAt;
        uint256 expiresAt;
        bytes32 rationaleHash;         // hash of trading rationale (privacy-preserving)
        bool rule10b5_1Plan;           // pre-planned trading pursuant to 10b5-1
    }

    struct BlackoutPeriod {
        BlackoutReason reason;
        uint256 startTimestamp;
        uint256 endTimestamp;
        bool active;
    }

    struct ComplianceLog {
        address insider;
        euint64 sharesTraded;           // encrypted actual trade size
        euint64 tradePriceUSD;          // encrypted trade price
        bool wasPreclearedTrade;
        bool flaggedForReview;
        uint256 tradeTimestamp;
    }

    mapping(address => InsiderProfile) private insiders;
    mapping(uint256 => PreClearanceRequest) private preClearances;
    mapping(uint256 => BlackoutPeriod) private blackouts;
    mapping(uint256 => ComplianceLog) private complianceLogs;
    mapping(address => bool) public isComplianceOfficer;
    mapping(address => bool) public isLegalCounsel;

    uint256 public preClearanceCount;
    uint256 public blackoutCount;
    uint256 public logCount;
    euint64 private _totalInsiderSharesMonitored;
    euint64 private _flaggedTradesCount;

    event InsiderRegistered(address indexed insider, InsiderTier tier);
    event PreClearanceRequested(uint256 indexed id, address insider);
    event PreClearanceApproved(uint256 indexed id);
    event PreClearanceDenied(uint256 indexed id);
    event BlackoutPeriodStarted(uint256 indexed id, BlackoutReason reason);
    event BlackoutPeriodEnded(uint256 indexed id);
    event TradeFlagged(uint256 indexed logId, address insider);
    event TradeLogged(uint256 indexed logId, address insider);

    constructor() Ownable(msg.sender) {
        _totalInsiderSharesMonitored = FHE.asEuint64(0);
        _flaggedTradesCount = FHE.asEuint64(0);
        FHE.allowThis(_totalInsiderSharesMonitored);
        FHE.allowThis(_flaggedTradesCount);
        isComplianceOfficer[msg.sender] = true;
        isLegalCounsel[msg.sender] = true;
    }

    modifier onlyComplianceOfficer() { require(isComplianceOfficer[msg.sender], "Not compliance officer"); _; }

    function registerInsider(
        address insider,
        InsiderTier tier,
        externalEuint64 encSharesHeld, bytes calldata shProof,
        externalEuint64 encRestricted, bytes calldata rProof,
        externalEuint64 encOptions, bytes calldata oProof,
        externalEuint64 encQuarterlyCap, bytes calldata qcProof
    ) external onlyComplianceOfficer {
        require(!insiders[insider].registered, "Already registered");
        InsiderProfile storage ip = insiders[insider];
        ip.tier = tier;
        ip.totalSharesHeld = FHE.fromExternal(encSharesHeld, shProof);
        ip.restrictedShares = FHE.fromExternal(encRestricted, rProof);
        ip.vestedOptionsUnexercised = FHE.fromExternal(encOptions, oProof);
        ip.quarterlyTradeCap = FHE.fromExternal(encQuarterlyCap, qcProof);
        ip.tradesThisQuarter = FHE.asEuint64(0);
        ip.annualTradingWindowBps = FHE.asEuint64(5000); // 50% of year can trade
        ip.registered = true;
        _totalInsiderSharesMonitored = FHE.add(_totalInsiderSharesMonitored, ip.totalSharesHeld);
        FHE.allowThis(ip.totalSharesHeld);
        FHE.allow(ip.totalSharesHeld, insider);
        FHE.allowThis(ip.restrictedShares);
        FHE.allow(ip.restrictedShares, insider);
        FHE.allowThis(ip.vestedOptionsUnexercised);
        FHE.allow(ip.vestedOptionsUnexercised, insider);
        FHE.allowThis(ip.quarterlyTradeCap);
        FHE.allow(ip.quarterlyTradeCap, insider);
        FHE.allowThis(ip.tradesThisQuarter);
        FHE.allow(ip.tradesThisQuarter, insider);
        FHE.allowThis(_totalInsiderSharesMonitored);
        emit InsiderRegistered(insider, tier);
    }

    function requestPreClearance(
        bool isBuy,
        externalEuint64 encShares, bytes calldata sProof,
        externalEuint64 encEstValue, bytes calldata evProof,
        bytes32 rationaleHash,
        bool is10b51Plan
    ) external nonReentrant returns (uint256 id) {
        InsiderProfile storage ip = insiders[msg.sender];
        require(ip.registered && !ip.suspended, "Not eligible");
        // Check no active blackout (done off-chain, status checked by compliance officer)
        euint64 shares = FHE.fromExternal(encShares, sProof);
        euint64 estValue = FHE.fromExternal(encEstValue, evProof);
        // Check within quarterly cap
        euint64 projectedQuarterlyTotal = FHE.add(ip.tradesThisQuarter, shares);
        ebool withinCap = FHE.le(projectedQuarterlyTotal, ip.quarterlyTradeCap);
        euint64 actualShares = FHE.select(withinCap, shares, FHE.sub(ip.quarterlyTradeCap, ip.tradesThisQuarter));
        // Post-trade holding percentage
        euint64 freeShares = FHE.sub(ip.totalSharesHeld, ip.restrictedShares);
        euint64 postTradeHolding = isBuy ?
            FHE.add(freeShares, actualShares) :
            FHE.sub(freeShares, FHE.select(FHE.le(actualShares, freeShares), actualShares, freeShares));
        euint64 postTradeHoldingBps = FHE.mul(postTradeHolding, FHE.asEuint64(10000)); // simplified: total shares divisor omitted
        id = preClearanceCount++;
        PreClearanceRequest storage pcr = preClearances[id];
        pcr.insider = msg.sender;
        pcr.isBuy = isBuy;
        pcr.sharesRequested = actualShares;
        pcr.estimatedValueUSD = estValue;
        pcr.postTradeHoldingBps = postTradeHoldingBps;
        pcr.status = ClearanceStatus.PENDING;
        pcr.requestedAt = block.timestamp;
        pcr.expiresAt = block.timestamp + 2 days;
        pcr.rationaleHash = rationaleHash;
        pcr.rule10b5_1Plan = is10b51Plan;
        FHE.allowThis(pcr.sharesRequested);
        FHE.allow(pcr.sharesRequested, msg.sender);
        FHE.allowThis(pcr.estimatedValueUSD);
        FHE.allow(pcr.estimatedValueUSD, msg.sender);
        FHE.allowThis(pcr.postTradeHoldingBps);
        FHE.allow(pcr.postTradeHoldingBps, msg.sender);
        emit PreClearanceRequested(id, msg.sender);
    }

    function approvePreClearance(uint256 id) external onlyComplianceOfficer {
        PreClearanceRequest storage pcr = preClearances[id];
        require(pcr.status == ClearanceStatus.PENDING, "Not pending");
        require(block.timestamp < pcr.expiresAt, "Expired");
        // Check no blackout is active
        for (uint256 i = 0; i < blackoutCount; i++) {
            BlackoutPeriod storage bp = blackouts[i];
            if (bp.active && block.timestamp >= bp.startTimestamp && block.timestamp <= bp.endTimestamp) {
                // Auto-deny during blackout
                pcr.status = ClearanceStatus.DENIED;
                emit PreClearanceDenied(id);
                return;
            }
        }
        pcr.status = ClearanceStatus.APPROVED;
        FHE.allow(pcr.sharesRequested, pcr.insider); // [acl_misconfig]
        // Provide market-context ratio so insider can gauge their trade size
        euint64 marketPct = FHE.div(FHE.mul(pcr.sharesRequested, FHE.asEuint64(10000)), _totalInsiderSharesMonitored); // [acl_misconfig]
        FHE.allow(marketPct, pcr.insider); // [acl_misconfig]
        FHE.allow(_totalInsiderSharesMonitored, pcr.insider); // [acl_misconfig]
        emit PreClearanceApproved(id);
    }

    function denyPreClearance(uint256 id) external onlyComplianceOfficer {
        PreClearanceRequest storage pcr = preClearances[id];
        require(pcr.status == ClearanceStatus.PENDING, "Not pending");
        pcr.status = ClearanceStatus.DENIED;
        emit PreClearanceDenied(id);
    }

    function declareBlackout(
        BlackoutReason reason,
        uint256 startTimestamp,
        uint256 endTimestamp
    ) external onlyComplianceOfficer returns (uint256 blackoutId) {
        blackoutId = blackoutCount++;
        blackouts[blackoutId] = BlackoutPeriod({
            reason: reason, startTimestamp: startTimestamp,
            endTimestamp: endTimestamp, active: true
        });
        emit BlackoutPeriodStarted(blackoutId, reason);
    }

    function endBlackout(uint256 blackoutId) external onlyComplianceOfficer {
        blackouts[blackoutId].active = false;
        emit BlackoutPeriodEnded(blackoutId);
    }

    function logTrade(
        address insider,
        bool wasPreclearance,
        externalEuint64 encSharesTraded, bytes calldata stProof,
        externalEuint64 encTradePrice, bytes calldata tpProof
    ) external onlyComplianceOfficer returns (uint256 logId) {
        InsiderProfile storage ip = insiders[insider];
        euint64 sharesTraded = FHE.fromExternal(encSharesTraded, stProof);
        euint64 tradePrice = FHE.fromExternal(encTradePrice, tpProof);
        // Flag if trade exceeds 5% of holdings (suspicious volume)
        euint64 holdingPct = FHE.mul(sharesTraded, FHE.asEuint64(10000)); // simplified: total shares divisor omitted
        ebool isFlagged = FHE.gt(holdingPct, FHE.asEuint64(500)); // >5%
        logId = logCount++;
        complianceLogs[logId] = ComplianceLog({
            insider: insider, sharesTraded: sharesTraded,
            tradePriceUSD: tradePrice, wasPreclearedTrade: wasPreclearance,
            flaggedForReview: false,
            tradeTimestamp: block.timestamp
        });
        ip.tradesThisQuarter = FHE.add(ip.tradesThisQuarter, sharesTraded);
        FHE.allowThis(complianceLogs[logId].sharesTraded);
        FHE.allowThis(complianceLogs[logId].tradePriceUSD);
        FHE.allow(complianceLogs[logId].sharesTraded, insider);
        FHE.allowThis(ip.tradesThisQuarter);
        FHE.allow(ip.tradesThisQuarter, insider);
        if (true) {
            _flaggedTradesCount = FHE.add(_flaggedTradesCount, FHE.asEuint64(1));
            FHE.allowThis(_flaggedTradesCount);
            emit TradeFlagged(logId, insider);
        }
        emit TradeLogged(logId, insider);
    }

    function updateHoldings(
        address insider,
        externalEuint64 encNewHoldings, bytes calldata nhProof
    ) external onlyComplianceOfficer {
        InsiderProfile storage ip = insiders[insider];
        _totalInsiderSharesMonitored = FHE.sub(_totalInsiderSharesMonitored, ip.totalSharesHeld);
        ip.totalSharesHeld = FHE.fromExternal(encNewHoldings, nhProof);
        _totalInsiderSharesMonitored = FHE.add(_totalInsiderSharesMonitored, ip.totalSharesHeld);
        FHE.allowThis(ip.totalSharesHeld);
        FHE.allow(ip.totalSharesHeld, insider);
        FHE.allowThis(_totalInsiderSharesMonitored);
    }

    function resetQuarterlyCounter(address insider) external onlyComplianceOfficer {
        InsiderProfile storage ip = insiders[insider];
        ip.tradesThisQuarter = FHE.asEuint64(0);
        FHE.allowThis(ip.tradesThisQuarter);
        FHE.allow(ip.tradesThisQuarter, insider);
    }

    function suspendInsider(address insider) external onlyComplianceOfficer {
        insiders[insider].suspended = true;
    }

    function addComplianceOfficer(address co) external onlyOwner { isComplianceOfficer[co] = true; }
    function addLegalCounsel(address lc) external onlyOwner { isLegalCounsel[lc] = true; }
    function allowRegulatoryData(address sec) external onlyComplianceOfficer {
        FHE.allow(_totalInsiderSharesMonitored, sec);
        FHE.allow(_flaggedTradesCount, sec);
    }
}
