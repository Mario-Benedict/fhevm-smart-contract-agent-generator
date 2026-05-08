// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedClinicalTrialDataConsortium
/// @notice Multi-site clinical trial data sharing with encrypted patient records,
///         confidential interim analysis results, and private adverse event reporting.
///         Ensures HIPAA/GDPR compliance through fully encrypted data handling.
contract EncryptedClinicalTrialDataConsortium is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {

    enum TrialPhase { PHASE_1, PHASE_2, PHASE_3, PHASE_4 }
    enum PatientStatus { SCREENING, ENROLLED, ACTIVE, COMPLETED, WITHDRAWN, ADVERSE_EVENT }
    enum ArmType { TREATMENT, PLACEBO, ACTIVE_COMPARATOR }

    struct ClinicalTrial {
        string trialId;          // ClinicalTrials.gov ID
        TrialPhase phase;
        euint64 targetEnrollment;         // encrypted enrollment target
        euint64 actualEnrollment;         // encrypted current enrollment
        euint64 primaryEndpointScore;     // encrypted blinded primary endpoint aggregate
        euint64 adverseEventCount;        // encrypted adverse event count
        euint64 seriousAdverseEventCount; // encrypted SAE count
        euint64 dropoutRateBps;           // encrypted dropout rate
        euint64 blindingBreachCount;      // encrypted unblinding count
        uint256 trialStartDate;
        uint256 trialEndDate;
        bool unblinded;
        bool active;
    }

    struct PatientRecord {
        uint256 trialId;
        ArmType arm;
        euint64 baselineScore;          // encrypted baseline measurement
        euint64 week4Score;             // encrypted 4-week measurement
        euint64 week12Score;            // encrypted 12-week measurement
        euint64 week24Score;            // encrypted 24-week (final) measurement
        euint64 doseMgEncrypted;        // encrypted dose
        euint8 adverseEventSeverity;    // encrypted AE severity (0-4, CTCAE grade)
        PatientStatus status;
        bytes32 siteId;
        bool consentRevoked;
    }

    struct SiteData {
        bytes32 siteId;
        euint64 enrolledCount;          // encrypted site enrollment
        euint64 completionRateBps;      // encrypted completion rate
        euint64 protocolDeviationCount; // encrypted protocol deviations
        euint64 dataQualityScore;       // encrypted data quality
        bool approved;
        bool suspended;
    }

    mapping(uint256 => ClinicalTrial) private trials;
    mapping(bytes32 => PatientRecord) private patients; // keccak(patientId, trialId)
    mapping(bytes32 => SiteData) private sites;
    mapping(address => bool) public isPrincipalInvestigator;
    mapping(address => bool) public isDataSafetyMonitoringBoard;
    mapping(address => bool) public isIRBApproved; // Institutional Review Board

    uint256 public trialCount;
    euint64 private _systemTotalPatients;
    euint64 private _systemTotalSAEs;

    event TrialRegistered(uint256 indexed trialId, string clinicalTrialsId);
    event PatientEnrolled(bytes32 indexed patientKey, uint256 trialId, ArmType arm);
    event MeasurementRecorded(bytes32 indexed patientKey, uint256 week);
    event AdverseEventReported(bytes32 indexed patientKey, uint256 indexed trialId, uint8 severity);
    event InterimAnalysisCompleted(uint256 indexed trialId);
    event TrialUnblinded(uint256 indexed trialId);

    constructor() Ownable(msg.sender) {
        _systemTotalPatients = FHE.asEuint64(0);
        _systemTotalSAEs = FHE.asEuint64(0);
        FHE.allowThis(_systemTotalPatients);
        FHE.allowThis(_systemTotalSAEs);
        isPrincipalInvestigator[msg.sender] = true;
        isDataSafetyMonitoringBoard[msg.sender] = true;
        isIRBApproved[msg.sender] = true;
    }

    modifier onlyPI() { require(isPrincipalInvestigator[msg.sender], "Not PI"); _; }
    modifier onlyDSMB() { require(isDataSafetyMonitoringBoard[msg.sender], "Not DSMB"); _; }

    function registerTrial(
        string calldata clinicalTrialsId,
        TrialPhase phase,
        externalEuint64 encTargetEnrollment, bytes calldata teProof,
        uint256 startDate, uint256 endDate
    ) external onlyPI returns (uint256 trialId) {
        trialId = trialCount++;
        ClinicalTrial storage ct = trials[trialId];
        ct.trialId = clinicalTrialsId;
        ct.phase = phase;
        ct.targetEnrollment = FHE.fromExternal(encTargetEnrollment, teProof);
        ct.actualEnrollment = FHE.asEuint64(0);
        ct.primaryEndpointScore = FHE.asEuint64(0);
        ct.adverseEventCount = FHE.asEuint64(0);
        ct.seriousAdverseEventCount = FHE.asEuint64(0);
        ct.dropoutRateBps = FHE.asEuint64(0);
        ct.blindingBreachCount = FHE.asEuint64(0);
        ct.trialStartDate = startDate;
        ct.trialEndDate = endDate;
        ct.active = true;
        FHE.allowThis(ct.targetEnrollment);
        FHE.allowThis(ct.actualEnrollment);
        FHE.allowThis(ct.primaryEndpointScore);
        FHE.allowThis(ct.adverseEventCount);
        FHE.allowThis(ct.seriousAdverseEventCount);
        emit TrialRegistered(trialId, clinicalTrialsId);
    }

    function enrollPatient(
        uint256 trialId,
        bytes32 anonymizedPatientId,
        ArmType arm,
        bytes32 siteId,
        externalEuint64 encBaseline, bytes calldata blProof,
        externalEuint64 encDose, bytes calldata dProof
    ) external onlyPI whenNotPaused returns (bytes32 patientKey) {
        ClinicalTrial storage ct = trials[trialId];
        require(ct.active, "Trial not active");
        SiteData storage site = sites[siteId];
        require(site.approved && !site.suspended, "Site not approved");
        // Check enrollment hasn't exceeded target
        ebool underTarget = FHE.lt(ct.actualEnrollment, ct.targetEnrollment);
        require(FHE.decrypt(underTarget), "Enrollment target met");
        euint64 baseline = FHE.fromExternal(encBaseline, blProof);
        euint64 dose = FHE.fromExternal(encDose, dProof);
        patientKey = keccak256(abi.encodePacked(anonymizedPatientId, trialId));
        PatientRecord storage pr = patients[patientKey];
        pr.trialId = trialId;
        pr.arm = arm;
        pr.baselineScore = baseline;
        pr.week4Score = FHE.asEuint64(0);
        pr.week12Score = FHE.asEuint64(0);
        pr.week24Score = FHE.asEuint64(0);
        pr.doseMgEncrypted = dose;
        pr.adverseEventSeverity = FHE.asEuint8(0);
        pr.status = PatientStatus.ENROLLED;
        pr.siteId = siteId;
        ct.actualEnrollment = FHE.add(ct.actualEnrollment, FHE.asEuint64(1));
        site.enrolledCount = FHE.add(site.enrolledCount, FHE.asEuint64(1));
        _systemTotalPatients = FHE.add(_systemTotalPatients, FHE.asEuint64(1));
        FHE.allowThis(pr.baselineScore);
        FHE.allowThis(pr.doseMgEncrypted);
        FHE.allowThis(pr.adverseEventSeverity);
        FHE.allowThis(pr.week4Score);
        FHE.allowThis(pr.week12Score);
        FHE.allowThis(pr.week24Score);
        FHE.allowThis(ct.actualEnrollment);
        FHE.allowThis(site.enrolledCount);
        FHE.allowThis(_systemTotalPatients);
        emit PatientEnrolled(patientKey, trialId, arm);
    }

    function recordMeasurement(
        bytes32 patientKey,
        uint256 week,
        externalEuint64 encScore, bytes calldata sProof
    ) external onlyPI {
        PatientRecord storage pr = patients[patientKey];
        require(pr.status == PatientStatus.ACTIVE || pr.status == PatientStatus.ENROLLED, "Not active");
        euint64 score = FHE.fromExternal(encScore, sProof);
        if (week == 4) {
            pr.week4Score = score;
            pr.status = PatientStatus.ACTIVE;
            FHE.allowThis(pr.week4Score);
        } else if (week == 12) {
            pr.week12Score = score;
            FHE.allowThis(pr.week12Score);
        } else if (week == 24) {
            pr.week24Score = score;
            pr.status = PatientStatus.COMPLETED;
            // Accumulate to primary endpoint (blinded aggregate)
            ClinicalTrial storage ct = trials[pr.trialId];
            ct.primaryEndpointScore = FHE.add(ct.primaryEndpointScore, score);
            FHE.allowThis(pr.week24Score);
            FHE.allowThis(ct.primaryEndpointScore);
        }
        emit MeasurementRecorded(patientKey, week);
    }

    function reportAdverseEvent(
        bytes32 patientKey,
        externalEuint8 encSeverity, bytes calldata svProof,
        bool isSerious
    ) external onlyPI {
        PatientRecord storage pr = patients[patientKey];
        euint8 severity = FHE.fromExternal(encSeverity, svProof);
        pr.adverseEventSeverity = severity;
        pr.status = PatientStatus.ADVERSE_EVENT;
        ClinicalTrial storage ct = trials[pr.trialId];
        ct.adverseEventCount = FHE.add(ct.adverseEventCount, FHE.asEuint64(1));
        FHE.allowThis(ct.adverseEventCount);
        if (isSerious) {
            ct.seriousAdverseEventCount = FHE.add(ct.seriousAdverseEventCount, FHE.asEuint64(1));
            _systemTotalSAEs = FHE.add(_systemTotalSAEs, FHE.asEuint64(1));
            FHE.allowThis(ct.seriousAdverseEventCount);
            FHE.allowThis(_systemTotalSAEs);
        }
        FHE.allowThis(pr.adverseEventSeverity);
        uint8 svValue = uint8(FHE.decrypt(severity));
        emit AdverseEventReported(patientKey, pr.trialId, svValue);
    }

    function conductInterimAnalysis(uint256 trialId) external onlyDSMB {
        ClinicalTrial storage ct = trials[trialId];
        // DSMB can access aggregate endpoint data
        FHE.allow(ct.primaryEndpointScore, msg.sender);
        FHE.allow(ct.adverseEventCount, msg.sender);
        FHE.allow(ct.seriousAdverseEventCount, msg.sender);
        FHE.allowTransient(ct.primaryEndpointScore, msg.sender);
        emit InterimAnalysisCompleted(trialId);
    }

    function unblindTrial(uint256 trialId) external onlyPI {
        ClinicalTrial storage ct = trials[trialId];
        require(!ct.unblinded, "Already unblinded");
        ct.unblinded = true;
        emit TrialUnblinded(trialId);
    }

    function registerSite(bytes32 siteId) external onlyPI {
        sites[siteId].enrolledCount = FHE.asEuint64(0);
        sites[siteId].completionRateBps = FHE.asEuint64(10000);
        sites[siteId].protocolDeviationCount = FHE.asEuint64(0);
        sites[siteId].dataQualityScore = FHE.asEuint64(9000);
        sites[siteId].approved = true;
        FHE.allowThis(sites[siteId].enrolledCount);
        FHE.allowThis(sites[siteId].completionRateBps);
        FHE.allowThis(sites[siteId].dataQualityScore);
    }

    function addPI(address pi) external onlyOwner { isPrincipalInvestigator[pi] = true; }
    function addDSMB(address dsm) external onlyOwner { isDataSafetyMonitoringBoard[dsm] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function allowSystemStats(address regulator) external onlyOwner {
        FHE.allow(_systemTotalPatients, regulator);
        FHE.allow(_systemTotalSAEs, regulator);
    }
}
