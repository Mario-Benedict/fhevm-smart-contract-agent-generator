// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateAntiMoneyLaunderingCompliance
/// @notice Encrypted AML compliance system: hidden transaction risk scores,
///         private suspicious activity thresholds, confidential SARs (Suspicious
///         Activity Reports), and encrypted watchlist matching results.
contract PrivateAntiMoneyLaunderingCompliance is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum RiskLevel { Low, Medium, High, Prohibited }
    enum SARStatus { Pending, Filed, Dismissed, Escalated }

    struct TransactionRiskAssessment {
        address sender;
        address receiver;
        euint64 amountUSD;             // encrypted transaction amount
        euint16 riskScore;             // encrypted risk score (0-10000)
        euint8  sanctionsMatchScore;   // encrypted sanctions hit score
        euint8  pepExposureScore;      // encrypted PEP exposure
        euint8  jurisdictionRiskScore; // encrypted jurisdiction risk
        RiskLevel riskLevel;
        uint256 assessedAt;
        bool flagged;
    }

    struct SuspiciousActivityReport {
        uint256 assessmentId;
        address reportingEntity;
        euint64 reportedAmountUSD;     // encrypted reported amount
        euint8  sarRiskScore;          // encrypted SAR severity
        SARStatus status;
        uint256 filedAt;
    }

    mapping(uint256 => TransactionRiskAssessment) private assessments;
    mapping(uint256 => SuspiciousActivityReport) private sars;
    mapping(address => euint8) private addressRiskFlag;   // encrypted per-address flag
    mapping(address => bool) public isComplianceOfficer;
    mapping(address => bool) public isAMLAnalyst;

    uint256 public assessmentCount;
    uint256 public sarCount;
    euint32 private _totalFlaggedTransactions;
    euint64 private _totalSuspiciousVolumeUSD;
    euint32 private _totalSARsFiled;

    event AssessmentRecorded(uint256 indexed id, RiskLevel level);
    event SARFiled(uint256 indexed sarId, uint256 assessmentId);
    event AddressFlagged(address indexed addr);

    modifier onlyComplianceOfficer() {
        require(isComplianceOfficer[msg.sender] || msg.sender == owner(), "Not compliance officer");
        _;
    }

    modifier onlyAMLAnalyst() {
        require(isAMLAnalyst[msg.sender] || isComplianceOfficer[msg.sender] || msg.sender == owner(), "Not AML analyst");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalFlaggedTransactions = FHE.asEuint32(0);
        _totalSuspiciousVolumeUSD = FHE.asEuint64(0);
        _totalSARsFiled = FHE.asEuint32(0);
        FHE.allowThis(_totalFlaggedTransactions);
        FHE.allowThis(_totalSuspiciousVolumeUSD);
        FHE.allowThis(_totalSARsFiled);
        isComplianceOfficer[msg.sender] = true;
        isAMLAnalyst[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addComplianceOfficer(address co) external onlyOwner { isComplianceOfficer[co] = true; }
    function addAMLAnalyst(address aa) external onlyOwner { isAMLAnalyst[aa] = true; }

    function recordAssessment(
        address sender, address receiver,
        externalEuint64 encAmount,      bytes calldata amProof,
        externalEuint16 encRiskScore,   bytes calldata rsProof,
        externalEuint8  encSanctions,   bytes calldata sanProof,
        externalEuint8  encPEP,         bytes calldata pepProof,
        externalEuint8  encJurisdiction,bytes calldata jurProof,
        RiskLevel level
    ) external onlyAMLAnalyst whenNotPaused returns (uint256 id) {
        euint64 amount    = FHE.fromExternal(encAmount, amProof);
        euint16 riskScore = FHE.fromExternal(encRiskScore, rsProof);
        euint8  sanctions = FHE.fromExternal(encSanctions, sanProof);
        euint8  pep       = FHE.fromExternal(encPEP, pepProof);
        euint8  jur       = FHE.fromExternal(encJurisdiction, jurProof);
        bool flagged = (level == RiskLevel.High || level == RiskLevel.Prohibited);
        id = assessmentCount++;
        assessments[id].sender = sender;
        assessments[id].receiver = receiver;
        assessments[id].amountUSD = amount;
        assessments[id].riskScore = riskScore;
        assessments[id].sanctionsMatchScore = sanctions;
        assessments[id].pepExposureScore = pep;
        assessments[id].jurisdictionRiskScore = jur;
        assessments[id].riskLevel = level;
        assessments[id].assessedAt = block.timestamp;
        assessments[id].flagged = flagged;
        if (flagged) {
            _totalFlaggedTransactions = FHE.add(_totalFlaggedTransactions, FHE.asEuint32(1));
            _totalSuspiciousVolumeUSD = FHE.add(_totalSuspiciousVolumeUSD, amount);
        }
        FHE.allowThis(assessments[id].amountUSD);
        FHE.allowThis(assessments[id].riskScore);
        FHE.allowThis(assessments[id].sanctionsMatchScore);
        FHE.allowThis(assessments[id].pepExposureScore);
        FHE.allowThis(assessments[id].jurisdictionRiskScore);
        FHE.allowThis(_totalFlaggedTransactions); FHE.allowThis(_totalSuspiciousVolumeUSD);
        emit AssessmentRecorded(id, level);
    }

    function fileSAR(
        uint256 assessmentId,
        externalEuint8 encSARScore, bytes calldata proof
    ) external onlyComplianceOfficer nonReentrant returns (uint256 sarId) {
        TransactionRiskAssessment storage a = assessments[assessmentId];
        require(a.flagged, "Not flagged");
        euint8 sarScore = FHE.fromExternal(encSARScore, proof);
        sarId = sarCount++;
        sars[sarId] = SuspiciousActivityReport({
            assessmentId: assessmentId, reportingEntity: msg.sender, reportedAmountUSD: a.amountUSD,
            sarRiskScore: sarScore, status: SARStatus.Filed, filedAt: block.timestamp
        });
        _totalSARsFiled = FHE.add(_totalSARsFiled, FHE.asEuint32(1));
        FHE.allowThis(sars[sarId].reportedAmountUSD);
        FHE.allowThis(sars[sarId].sarRiskScore);
        FHE.allowThis(_totalSARsFiled);
        emit SARFiled(sarId, assessmentId);
    }

    function flagAddress(address addr, externalEuint8 encFlag, bytes calldata proof) external onlyComplianceOfficer {
        euint8 flag = FHE.fromExternal(encFlag, proof);
        addressRiskFlag[addr] = flag;
        FHE.allowThis(addressRiskFlag[addr]);
        emit AddressFlagged(addr);
    }

    function allowComplianceStats(address viewer) external onlyOwner {
        FHE.allow(_totalFlaggedTransactions, viewer);
        FHE.allow(_totalSuspiciousVolumeUSD, viewer);
        FHE.allow(_totalSARsFiled, viewer);
    }

    function getAddressRiskFlag(address addr) external view returns (euint8) { return addressRiskFlag[addr]; }
    function allowRiskFlagView(address addr, address viewer) external onlyComplianceOfficer { FHE.allow(addressRiskFlag[addr], viewer); }
}
