// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedDrugSafetyPhaseIITrial
/// @notice Encrypted clinical trial management for Phase II drug safety.
///         Patient dosage, adverse events severity, and efficacy scores
///         are fully encrypted. IRB approval gates phase progression.
contract EncryptedDrugSafetyPhaseIITrial is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum TrialPhase { Setup, Enrollment, Treatment, FollowUp, Analysis, Closed }
    enum ArmAssignment { Control, LowDose, MidDose, HighDose }
    enum AdverseEventGrade { None, Mild, Moderate, Severe, LifeThreatening }

    struct TrialParticipant {
        uint256 participantId;
        ArmAssignment arm;
        euint8 baselineHealthScore;   // encrypted 0-100
        euint32 dosageMicrogramsDay;  // encrypted daily dose
        euint8 currentHealthScore;    // encrypted current health
        euint16 adverseEventScore;    // encrypted cumulative AE score
        euint8 efficacyResponse;      // encrypted response rate 0-100
        euint32 biomarkerLevel;       // encrypted primary biomarker
        bool enrolled;
        bool withdrawn;
        uint256 enrolledAt;
    }

    struct SafetySignal {
        uint256 participantId;
        AdverseEventGrade grade;
        euint16 severityScore;        // encrypted severity 0-1000
        euint64 reportedAt;
        bool adjudicated;
        bool causedWithdrawal;
    }

    mapping(uint256 => TrialParticipant) private participants;
    mapping(uint256 => SafetySignal[]) private safetySignals;
    mapping(address => bool) public isPrincipalInvestigator;
    mapping(address => bool) public isIRBMember;
    mapping(address => bool) public isSafetyMonitor;

    uint256 public participantCount;
    TrialPhase public trialPhase;
    string public trialId;
    string public drugName;

    euint64 private _totalParticipants;
    euint64 private _totalWithdrawals;
    euint32 private _avgEfficacyScore;
    euint32 private _avgAdverseEventScore;

    event ParticipantEnrolled(uint256 indexed id, ArmAssignment arm);
    event DoseAdministered(uint256 indexed id);
    event AdverseEventReported(uint256 indexed participantId, AdverseEventGrade grade);
    event PhaseAdvanced(TrialPhase newPhase);
    event ParticipantWithdrawn(uint256 indexed id);
    event TrialClosed();

    modifier onlyPI() {
        require(isPrincipalInvestigator[msg.sender] || msg.sender == owner(), "Not PI");
        _;
    }
    modifier onlyIRB() {
        require(isIRBMember[msg.sender] || msg.sender == owner(), "Not IRB");
        _;
    }
    modifier onlySafetyMonitor() {
        require(isSafetyMonitor[msg.sender] || msg.sender == owner(), "Not safety monitor");
        _;
    }

    constructor(string memory _trialId, string memory _drugName) Ownable(msg.sender) {
        trialId = _trialId;
        drugName = _drugName;
        trialPhase = TrialPhase.Setup;
        _totalParticipants = FHE.asEuint64(0);
        _totalWithdrawals = FHE.asEuint64(0);
        _avgEfficacyScore = FHE.asEuint32(0);
        _avgAdverseEventScore = FHE.asEuint32(0);
        FHE.allowThis(_totalParticipants);
        FHE.allowThis(_totalWithdrawals);
        FHE.allowThis(_avgEfficacyScore);
        FHE.allowThis(_avgAdverseEventScore);
        isPrincipalInvestigator[msg.sender] = true;
    }

    function addPI(address pi) external onlyOwner { isPrincipalInvestigator[pi] = true; }
    function addIRB(address irb) external onlyOwner { isIRBMember[irb] = true; }
    function addSafetyMonitor(address sm) external onlyOwner { isSafetyMonitor[sm] = true; }

    function enrollParticipant(
        ArmAssignment arm,
        externalEuint8 encBaseline, bytes calldata baseProof,
        externalEuint32 encDosage, bytes calldata doseProof,
        externalEuint32 encBiomarker, bytes calldata bioProof
    ) external onlyPI returns (uint256 pid) {
        require(trialPhase == TrialPhase.Enrollment, "Not in enrollment");
        pid = participantCount++;
        TrialParticipant storage p = participants[pid];
        p.participantId = pid;
        p.arm = arm;
        p.baselineHealthScore = FHE.fromExternal(encBaseline, baseProof);
        p.dosageMicrogramsDay = FHE.fromExternal(encDosage, doseProof);
        p.currentHealthScore = p.baselineHealthScore;
        p.adverseEventScore = FHE.asEuint16(0);
        p.efficacyResponse = FHE.asEuint8(0);
        p.biomarkerLevel = FHE.fromExternal(encBiomarker, bioProof);
        p.enrolled = true;
        p.enrolledAt = block.timestamp;
        _totalParticipants = FHE.add(_totalParticipants, FHE.asEuint64(1));
        FHE.allowThis(p.baselineHealthScore);
        FHE.allowThis(p.dosageMicrogramsDay);
        FHE.allowThis(p.currentHealthScore);
        FHE.allowThis(p.adverseEventScore);
        FHE.allowThis(p.efficacyResponse);
        FHE.allowThis(p.biomarkerLevel);
        FHE.allowThis(_totalParticipants);
        emit ParticipantEnrolled(pid, arm);
    }

    function recordTreatmentVisit(
        uint256 pid,
        externalEuint8 encHealthScore, bytes calldata hsProof,
        externalEuint8 encEfficacy, bytes calldata effProof,
        externalEuint32 encBiomarker, bytes calldata bioProof
    ) external onlyPI {
        require(trialPhase == TrialPhase.Treatment || trialPhase == TrialPhase.FollowUp, "Wrong phase");
        TrialParticipant storage p = participants[pid];
        require(p.enrolled && !p.withdrawn, "Not active");
        p.currentHealthScore = FHE.fromExternal(encHealthScore, hsProof);
        p.efficacyResponse = FHE.fromExternal(encEfficacy, effProof);
        p.biomarkerLevel = FHE.fromExternal(encBiomarker, bioProof);
        _avgEfficacyScore = FHE.add(
            FHE.div(_avgEfficacyScore, 2),
            FHE.div(FHE.asEuint32(p.efficacyResponse), 2)
        );
        FHE.allowThis(p.currentHealthScore);
        FHE.allowThis(p.efficacyResponse);
        FHE.allowThis(p.biomarkerLevel);
        FHE.allowThis(_avgEfficacyScore);
        emit DoseAdministered(pid);
    }

    function reportAdverseEvent(
        uint256 pid,
        AdverseEventGrade grade,
        externalEuint16 encSeverity, bytes calldata sevProof,
        bool causedWithdrawal
    ) external onlySafetyMonitor {
        euint16 severity = FHE.fromExternal(encSeverity, sevProof);
        TrialParticipant storage p = participants[pid];
        p.adverseEventScore = FHE.add(p.adverseEventScore, severity);
        uint256 sigIdx = safetySignals[pid].length;
        safetySignals[pid].push(SafetySignal({
            participantId: pid,
            grade: grade,
            severityScore: severity,
            reportedAt: FHE.asEuint64(uint64(block.timestamp)),
            adjudicated: false,
            causedWithdrawal: causedWithdrawal
        }));
        FHE.allowThis(safetySignals[pid][sigIdx].severityScore);
        FHE.allowThis(safetySignals[pid][sigIdx].reportedAt);
        FHE.allowThis(p.adverseEventScore);
        if (causedWithdrawal) {
            p.withdrawn = true;
            _totalWithdrawals = FHE.add(_totalWithdrawals, FHE.asEuint64(1));
            FHE.allowThis(_totalWithdrawals);
            emit ParticipantWithdrawn(pid);
        }
        emit AdverseEventReported(pid, grade);
    }

    function advancePhase() external onlyIRB {
        require(uint8(trialPhase) < uint8(TrialPhase.Closed), "Already closed");
        trialPhase = TrialPhase(uint8(trialPhase) + 1);
        if (trialPhase == TrialPhase.Closed) emit TrialClosed();
        else emit PhaseAdvanced(trialPhase);
    }

    function allowParticipantView(uint256 pid, address viewer) external onlyPI {
        TrialParticipant storage p = participants[pid];
        FHE.allow(p.currentHealthScore, viewer);
        FHE.allow(p.efficacyResponse, viewer);
        FHE.allow(p.adverseEventScore, viewer);
        FHE.allow(p.biomarkerLevel, viewer);
    }

    function allowTrialStats(address viewer) external onlyOwner {
        FHE.allow(_totalParticipants, viewer);
        FHE.allow(_totalWithdrawals, viewer);
        FHE.allow(_avgEfficacyScore, viewer);
    }
}
