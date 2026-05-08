// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCentralBankReserveAudit
/// @notice Central bank encrypted reserve management and audit.
///         Foreign exchange reserves, gold holdings, and tier-1 capital
///         ratios are tracked with encrypted values. IMF auditors get read access.
contract EncryptedCentralBankReserveAudit is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ReserveAssetClass { Gold, USD, EUR, SDR, BondPortfolio, EquityPortfolio, CryptoCustody }
    enum AuditStatus { Pending, InProgress, Certified, Qualified, Adverse }

    struct ReservePosition {
        ReserveAssetClass assetClass;
        euint64 nominalValueUSD;        // encrypted USD equivalent
        euint32 allocationBps;          // encrypted portfolio weight
        euint32 durationYearsX100;      // encrypted modified duration * 100
        euint32 yieldBps;               // encrypted current yield
        euint64 unrealizedGainLossUSD;  // encrypted MTM P&L
        bool active;
        uint256 lastUpdated;
    }

    struct CapitalRatioRecord {
        euint32 tier1CapitalRatioBps;   // encrypted CET1
        euint32 leverageRatioBps;       // encrypted leverage ratio
        euint32 liquidityCoverageRatioBps; // encrypted LCR
        euint32 netStableFundingRatioBps;  // encrypted NSFR
        uint256 recordedAt;
    }

    struct AuditRound {
        uint256 roundId;
        address leadAuditor;
        AuditStatus status;
        euint64 auditedReserveTotal;   // encrypted total reserves audited
        euint32 confidenceScoreBps;    // encrypted audit confidence
        string auditFirmName;
        uint256 auditStarted;
        uint256 auditCompleted;
    }

    mapping(uint256 => ReservePosition) private reserves;
    mapping(uint256 => CapitalRatioRecord) private capitalHistory;
    mapping(uint256 => AuditRound) private audits;
    mapping(address => bool) public isIMFAuditor;
    mapping(address => bool) public isCentralBankOfficial;

    uint256 public reservePositionCount;
    uint256 public capitalRecordCount;
    uint256 public auditCount;

    euint64 private _totalReservesUSD;
    euint64 private _goldReservesUSD;
    euint32 private _weightedAverageDuration;

    event ReservePositionUpdated(uint256 indexed positionId, ReserveAssetClass assetClass);
    event CapitalRatioRecorded(uint256 indexed recordId);
    event AuditInitiated(uint256 indexed auditId, address leadAuditor);
    event AuditCompleted(uint256 indexed auditId, AuditStatus status);
    event ReserveAlert(string alertType, uint256 positionId);

    modifier onlyCBOfficial() {
        require(isCentralBankOfficial[msg.sender] || msg.sender == owner(), "Not CB official");
        _;
    }

    modifier onlyAuditor() {
        require(isIMFAuditor[msg.sender] || msg.sender == owner(), "Not IMF auditor");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalReservesUSD = FHE.asEuint64(0);
        _goldReservesUSD = FHE.asEuint64(0);
        _weightedAverageDuration = FHE.asEuint32(0);
        FHE.allowThis(_totalReservesUSD);
        FHE.allowThis(_goldReservesUSD);
        FHE.allowThis(_weightedAverageDuration);
        isCentralBankOfficial[msg.sender] = true;
        isIMFAuditor[msg.sender] = true;
    }

    function addCBOfficial(address off) external onlyOwner { isCentralBankOfficial[off] = true; }
    function addIMFAuditor(address aud) external onlyOwner { isIMFAuditor[aud] = true; }

    function updateReservePosition(
        uint256 positionId,
        ReserveAssetClass assetClass,
        externalEuint64 encNominal, bytes calldata nomProof,
        externalEuint32 encAllocation, bytes calldata allocProof,
        externalEuint32 encDuration, bytes calldata durProof,
        externalEuint32 encYield, bytes calldata yieldProof,
        externalEuint64 encMTM, bytes calldata mtmProof
    ) external onlyCBOfficial {
        euint64 nominal = FHE.fromExternal(encNominal, nomProof);
        euint32 allocation = FHE.fromExternal(encAllocation, allocProof);
        euint32 duration = FHE.fromExternal(encDuration, durProof);
        euint32 yieldRate = FHE.fromExternal(encYield, yieldProof);
        euint64 mtm = FHE.fromExternal(encMTM, mtmProof);

        ReservePosition storage pos = reserves[positionId];
        bool isNew = !pos.active;
        if (isNew) reservePositionCount++;

        pos.assetClass = assetClass;
        pos.nominalValueUSD = nominal;
        pos.allocationBps = allocation;
        pos.durationYearsX100 = duration;
        pos.yieldBps = yieldRate;
        pos.unrealizedGainLossUSD = mtm;
        pos.active = true;
        pos.lastUpdated = block.timestamp;

        // Update totals
        if (isNew) {
            _totalReservesUSD = FHE.add(_totalReservesUSD, nominal);
            if (assetClass == ReserveAssetClass.Gold) {
                _goldReservesUSD = FHE.add(_goldReservesUSD, nominal);
            }
        }

        FHE.allowThis(pos.nominalValueUSD);
        FHE.allowThis(pos.allocationBps);
        FHE.allowThis(pos.durationYearsX100);
        FHE.allowThis(pos.yieldBps);
        FHE.allowThis(pos.unrealizedGainLossUSD);
        FHE.allowThis(_totalReservesUSD);
        FHE.allowThis(_goldReservesUSD);

        emit ReservePositionUpdated(positionId, assetClass);
    }

    function recordCapitalRatios(
        externalEuint32 encTier1, bytes calldata t1Proof,
        externalEuint32 encLeverage, bytes calldata levProof,
        externalEuint32 encLCR, bytes calldata lcrProof,
        externalEuint32 encNSFR, bytes calldata nsfrProof
    ) external onlyCBOfficial {
        euint32 tier1 = FHE.fromExternal(encTier1, t1Proof);
        euint32 leverage = FHE.fromExternal(encLeverage, levProof);
        euint32 lcr = FHE.fromExternal(encLCR, lcrProof);
        euint32 nsfr = FHE.fromExternal(encNSFR, nsfrProof);

        uint256 rid = capitalRecordCount++;
        capitalHistory[rid].tier1CapitalRatioBps = tier1;
        capitalHistory[rid].leverageRatioBps = leverage;
        capitalHistory[rid].liquidityCoverageRatioBps = lcr;
        capitalHistory[rid].netStableFundingRatioBps = nsfr;
        capitalHistory[rid].recordedAt = block.timestamp;

        // Alert if Tier1 < 4.5% (450 bps) Basel III minimum
        ebool belowMin = FHE.lt(tier1, FHE.asEuint32(450));
        if (FHE.isInitialized(belowMin)) emit ReserveAlert("Tier1BelowBaselMinimum", rid);

        FHE.allowThis(capitalHistory[rid].tier1CapitalRatioBps);
        FHE.allowThis(capitalHistory[rid].leverageRatioBps);
        FHE.allowThis(capitalHistory[rid].liquidityCoverageRatioBps);
        FHE.allowThis(capitalHistory[rid].netStableFundingRatioBps);

        emit CapitalRatioRecorded(rid);
    }

    function initiateAudit(
        address leadAuditor,
        string calldata auditFirm
    ) external onlyAuditor returns (uint256 auditId) {
        auditId = auditCount++;
        AuditRound storage aud = audits[auditId];
        aud.roundId = auditId;
        aud.leadAuditor = leadAuditor;
        aud.status = AuditStatus.InProgress;
        aud.auditedReserveTotal = FHE.asEuint64(0);
        aud.confidenceScoreBps = FHE.asEuint32(0);
        aud.auditFirmName = auditFirm;
        aud.auditStarted = block.timestamp;
        FHE.allowThis(aud.auditedReserveTotal);
        FHE.allowThis(aud.confidenceScoreBps);
        emit AuditInitiated(auditId, leadAuditor);
    }

    function completeAudit(
        uint256 auditId,
        AuditStatus finalStatus,
        externalEuint64 encAuditedTotal, bytes calldata totProof,
        externalEuint32 encConfidence, bytes calldata confProof
    ) external onlyAuditor {
        AuditRound storage aud = audits[auditId];
        require(aud.status == AuditStatus.InProgress, "Not in progress");
        aud.auditedReserveTotal = FHE.fromExternal(encAuditedTotal, totProof);
        aud.confidenceScoreBps = FHE.fromExternal(encConfidence, confProof);
        aud.status = finalStatus;
        aud.auditCompleted = block.timestamp;
        FHE.allowThis(aud.auditedReserveTotal);
        FHE.allowThis(aud.confidenceScoreBps);
        emit AuditCompleted(auditId, finalStatus);
    }

    function allowReserveView(address viewer) external onlyAuditor {
        FHE.allow(_totalReservesUSD, viewer);
        FHE.allow(_goldReservesUSD, viewer);
        FHE.allow(_weightedAverageDuration, viewer);
    }

    function allowPositionView(uint256 positionId, address viewer) external onlyAuditor {
        FHE.allow(reserves[positionId].nominalValueUSD, viewer);
        FHE.allow(reserves[positionId].allocationBps, viewer);
        FHE.allow(reserves[positionId].yieldBps, viewer);
    }

    function allowCapitalView(uint256 recordId, address viewer) external onlyAuditor {
        FHE.allow(capitalHistory[recordId].tier1CapitalRatioBps, viewer);
        FHE.allow(capitalHistory[recordId].leverageRatioBps, viewer);
        FHE.allow(capitalHistory[recordId].liquidityCoverageRatioBps, viewer);
    }
}
