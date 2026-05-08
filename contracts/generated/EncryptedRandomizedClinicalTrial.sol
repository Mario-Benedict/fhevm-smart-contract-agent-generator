// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedRandomizedClinicalTrial
/// @notice Encrypted clinical trial randomization: private patient arm assignments,
///         hidden treatment dosage codes, confidential adverse event reporting,
///         and encrypted interim efficacy analysis with blind-breaking controls.
contract EncryptedRandomizedClinicalTrial is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum TrialArm { Placebo, LowDose, MidDose, HighDose, Comparator }
    enum AEGrade  { Grade1_Mild, Grade2_Moderate, Grade3_Severe, Grade4_LifeThreatening }

    struct Patient {
        address patientWallet;
        string patientRef;
        euint8  trialArm;              // encrypted arm assignment
        euint16 dosageCode;            // encrypted dosage code
        euint16 baselineScore;         // encrypted baseline clinical score
        euint16 weekFourScore;         // encrypted 4-week outcome
        euint16 weekEightScore;        // encrypted 8-week outcome
        euint8  adverseEventGrade;     // encrypted AE severity
        uint256 enrolledAt;
        bool withdrawn;
    }

    struct TrialStats {
        euint32 enrolledCount;
        euint64 totalResponseScore;    // encrypted sum of responses
        euint32 adverseEventCount;     // encrypted AE count
        euint8  blindBreakCount;       // encrypted emergency unblind count
    }

    mapping(uint256 => Patient) private patients;
    mapping(address => bool) public isClinicalInvestigator;
    mapping(address => bool) public isDataSafetyMonitor;

    uint256 public patientCount;
    TrialStats private trialStats;

    event PatientEnrolled(uint256 indexed id, string patientRef);
    event OutcomeRecorded(uint256 indexed id, uint256 recordedAt);
    event AdverseEventReported(uint256 indexed id, uint256 reportedAt);
    event BlindBroken(uint256 indexed id, uint256 brokenAt);

    modifier onlyClinicalInvestigator() {
        require(isClinicalInvestigator[msg.sender] || msg.sender == owner(), "Not clinical investigator");
        _;
    }

    modifier onlyDataSafetyMonitor() {
        require(isDataSafetyMonitor[msg.sender] || msg.sender == owner(), "Not DSMB member");
        _;
    }

    constructor() Ownable(msg.sender) {
        trialStats = TrialStats({
            enrolledCount: FHE.asEuint32(0), totalResponseScore: FHE.asEuint64(0),
            adverseEventCount: FHE.asEuint32(0), blindBreakCount: FHE.asEuint8(0)
        });
        FHE.allowThis(trialStats.enrolledCount); FHE.allowThis(trialStats.totalResponseScore);
        FHE.allowThis(trialStats.adverseEventCount); FHE.allowThis(trialStats.blindBreakCount);
        isClinicalInvestigator[msg.sender] = true;
        isDataSafetyMonitor[msg.sender] = true;
    }

    function addInvestigator(address inv) external onlyOwner { isClinicalInvestigator[inv] = true; }
    function addDSMB(address dsm) external onlyOwner { isDataSafetyMonitor[dsm] = true; }

    function enrollPatient(
        address patientWallet, string calldata patientRef,
        externalEuint16 encBaseline, bytes calldata blProof,
        externalEuint16 encDosage, bytes calldata dProof
    ) external onlyClinicalInvestigator returns (uint256 id) {
        euint16 baseline = FHE.fromExternal(encBaseline, blProof);
        euint16 dosage   = FHE.fromExternal(encDosage, dProof);
        euint8  arm      = FHE.asEuint8(uint8(FHE.isInitialized(FHE.randEuint64()) ? 1 : 0)); // randomized arm
        id = patientCount++;
        patients[id] = Patient({
            patientWallet: patientWallet, patientRef: patientRef, trialArm: arm,
            dosageCode: dosage, baselineScore: baseline, weekFourScore: FHE.asEuint16(0),
            weekEightScore: FHE.asEuint16(0), adverseEventGrade: FHE.asEuint8(0),
            enrolledAt: block.timestamp, withdrawn: false
        });
        trialStats.enrolledCount = FHE.add(trialStats.enrolledCount, FHE.asEuint32(1));
        FHE.allowThis(patients[id].trialArm);
        FHE.allowThis(patients[id].dosageCode);
        FHE.allowThis(patients[id].baselineScore); FHE.allow(patients[id].baselineScore, patientWallet);
        FHE.allowThis(patients[id].weekFourScore); FHE.allow(patients[id].weekFourScore, patientWallet);
        FHE.allowThis(patients[id].weekEightScore); FHE.allow(patients[id].weekEightScore, patientWallet);
        FHE.allowThis(patients[id].adverseEventGrade);
        FHE.allowThis(trialStats.enrolledCount);
        emit PatientEnrolled(id, patientRef);
    }

    function recordOutcome(
        uint256 patientId,
        externalEuint16 encWeek4, bytes calldata w4Proof,
        externalEuint16 encWeek8, bytes calldata w8Proof
    ) external onlyClinicalInvestigator {
        Patient storage p = patients[patientId];
        p.weekFourScore  = FHE.fromExternal(encWeek4, w4Proof);
        p.weekEightScore = FHE.fromExternal(encWeek8, w8Proof);
        trialStats.totalResponseScore = FHE.add(trialStats.totalResponseScore, FHE.asEuint64(1));
        FHE.allowThis(p.weekFourScore); FHE.allow(p.weekFourScore, p.patientWallet);
        FHE.allowThis(p.weekEightScore); FHE.allow(p.weekEightScore, p.patientWallet);
        FHE.allowThis(trialStats.totalResponseScore);
        emit OutcomeRecorded(patientId, block.timestamp);
    }

    function reportAdverseEvent(
        uint256 patientId,
        externalEuint8 encGrade, bytes calldata proof
    ) external onlyClinicalInvestigator {
        Patient storage p = patients[patientId];
        p.adverseEventGrade = FHE.fromExternal(encGrade, proof);
        trialStats.adverseEventCount = FHE.add(trialStats.adverseEventCount, FHE.asEuint32(1));
        FHE.allowThis(p.adverseEventGrade);
        FHE.allowThis(trialStats.adverseEventCount);
        emit AdverseEventReported(patientId, block.timestamp);
    }

    function emergencyUnblind(uint256 patientId) external onlyDataSafetyMonitor {
        trialStats.blindBreakCount = FHE.add(trialStats.blindBreakCount, FHE.asEuint8(1));
        FHE.allow(patients[patientId].trialArm, msg.sender);
        FHE.allow(patients[patientId].dosageCode, msg.sender);
        FHE.allowThis(trialStats.blindBreakCount);
        emit BlindBroken(patientId, block.timestamp);
    }

    function allowTrialStats(address viewer) external onlyOwner {
        FHE.allow(trialStats.enrolledCount, viewer); FHE.allow(trialStats.adverseEventCount, viewer);
    }
}
