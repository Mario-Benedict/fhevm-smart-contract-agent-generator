// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateOncologyTreatmentRegistry
/// @notice Cancer treatment outcome registry: encrypted tumor markers, encrypted treatment response scores,
///         encrypted survival predictions, and confidential clinical trial eligibility scoring.
contract PrivateOncologyTreatmentRegistry is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum CancerType { BREAST, LUNG, COLORECTAL, PROSTATE, MELANOMA, LEUKEMIA, LYMPHOMA }
    enum TreatmentType { CHEMOTHERAPY, IMMUNOTHERAPY, TARGETED_THERAPY, RADIATION, SURGERY, COMBINATION }

    struct PatientRecord {
        bytes32 patientHash;
        CancerType cancerType;
        euint8 stageAtDiagnosis;       // encrypted cancer stage 1-4
        euint64 primaryTumorSizeMm;    // encrypted tumor size
        euint64 biomarkerScore;        // encrypted biomarker panel score
        euint64 treatmentResponseBps;  // encrypted treatment response rate
        euint64 survivalProbBps;       // encrypted 5-year survival probability
        euint64 trialEligibilityScore; // encrypted clinical trial eligibility
        uint256 diagnosisDate;
        bool active;
    }

    struct TreatmentCourse {
        bytes32 patientHash;
        TreatmentType treatment;
        euint64 doseIntensity;         // encrypted dose mg/m2
        euint64 cycleCount;            // encrypted number of cycles
        euint64 responseScore;         // encrypted RECIST response score
        euint64 toxicityScore;         // encrypted toxicity/AE score 0-1000
        euint64 qualityOfLifeScore;    // encrypted QoL score 0-100
        uint256 startDate;
        uint256 endDate;
        bool completed;
    }

    mapping(bytes32 => PatientRecord) private patients;
    mapping(uint256 => TreatmentCourse) private courses;
    uint256 public courseCount;
    euint64 private _cohortSurvivalAvg;
    mapping(address => bool) public isOncologist;
    mapping(address => bool) public isResearchCoordinator;

    event PatientRegistered(bytes32 indexed patientHash, CancerType ctype);
    event TreatmentStarted(uint256 indexed courseId, bytes32 patientHash);
    event TreatmentCompleted(uint256 indexed courseId);
    event OutcomeUpdated(bytes32 indexed patientHash);

    constructor() Ownable(msg.sender) {
        _cohortSurvivalAvg = FHE.asEuint64(0);
        FHE.allowThis(_cohortSurvivalAvg);
        isOncologist[msg.sender] = true;
        isResearchCoordinator[msg.sender] = true;
    }

    function addOncologist(address o) external onlyOwner { isOncologist[o] = true; }
    function addCoordinator(address c) external onlyOwner { isResearchCoordinator[c] = true; }

    function registerPatient(
        bytes32 patientHash, CancerType ctype,
        externalEuint8 encStage, bytes calldata stProof,
        externalEuint64 encTumorSize, bytes calldata tsProof,
        externalEuint64 encBiomarker, bytes calldata bmProof,
        externalEuint64 encSurvival, bytes calldata svProof
    ) external {
        require(isOncologist[msg.sender], "Not oncologist");
        euint8 stage = FHE.fromExternal(encStage, stProof);
        euint64 tumorSize = FHE.fromExternal(encTumorSize, tsProof);
        euint64 biomarker = FHE.fromExternal(encBiomarker, bmProof);
        euint64 survival = FHE.fromExternal(encSurvival, svProof);
        // Stage 4 => lower eligibility score
        ebool advancedStage = FHE.ge(stage, FHE.asEuint8(4));
        euint64 eligibility = FHE.select(advancedStage, FHE.asEuint64(400), FHE.asEuint64(800));
        patients[patientHash] = PatientRecord({
            patientHash: patientHash, cancerType: ctype, stageAtDiagnosis: stage,
            primaryTumorSizeMm: tumorSize, biomarkerScore: biomarker,
            treatmentResponseBps: FHE.asEuint64(0), survivalProbBps: survival,
            trialEligibilityScore: eligibility, diagnosisDate: block.timestamp, active: true
        });
        FHE.allowThis(patients[patientHash].stageAtDiagnosis);
        FHE.allowThis(patients[patientHash].primaryTumorSizeMm);
        FHE.allowThis(patients[patientHash].biomarkerScore);
        FHE.allowThis(patients[patientHash].survivalProbBps);
        FHE.allowThis(patients[patientHash].trialEligibilityScore);
        FHE.allowThis(patients[patientHash].treatmentResponseBps);
        _cohortSurvivalAvg = FHE.div(FHE.add(_cohortSurvivalAvg, survival), 2);
        FHE.allowThis(_cohortSurvivalAvg);
        emit PatientRegistered(patientHash, ctype);
    }

    function startTreatment(
        bytes32 patientHash, TreatmentType treatment,
        externalEuint64 encDose, bytes calldata dProof,
        externalEuint64 encCycles, bytes calldata cyProof
    ) external returns (uint256 courseId) {
        require(isOncologist[msg.sender], "Not oncologist");
        euint64 dose = FHE.fromExternal(encDose, dProof);
        euint64 cycles = FHE.fromExternal(encCycles, cyProof);
        courseId = courseCount++;
        courses[courseId] = TreatmentCourse({
            patientHash: patientHash, treatment: treatment,
            doseIntensity: dose, cycleCount: cycles,
            responseScore: FHE.asEuint64(0), toxicityScore: FHE.asEuint64(0),
            qualityOfLifeScore: FHE.asEuint64(0),
            startDate: block.timestamp, endDate: 0, completed: false
        });
        FHE.allowThis(courses[courseId].doseIntensity);
        FHE.allowThis(courses[courseId].cycleCount);
        FHE.allowThis(courses[courseId].responseScore);
        FHE.allowThis(courses[courseId].toxicityScore);
        FHE.allowThis(courses[courseId].qualityOfLifeScore);
        emit TreatmentStarted(courseId, patientHash);
    }

    function completeTreatment(
        uint256 courseId,
        externalEuint64 encResponse, bytes calldata rProof,
        externalEuint64 encToxicity, bytes calldata tProof,
        externalEuint64 encQoL, bytes calldata qolProof
    ) external {
        require(isOncologist[msg.sender], "Not oncologist");
        TreatmentCourse storage course = courses[courseId];
        require(!course.completed, "Already done");
        euint64 response = FHE.fromExternal(encResponse, rProof);
        euint64 toxicity = FHE.fromExternal(encToxicity, tProof);
        euint64 qol = FHE.fromExternal(encQoL, qolProof);
        course.responseScore = response;
        course.toxicityScore = toxicity;
        course.qualityOfLifeScore = qol;
        course.endDate = block.timestamp;
        course.completed = true;
        // Update patient treatment response
        patients[course.patientHash].treatmentResponseBps = response;
        FHE.allowThis(course.responseScore);
        FHE.allowThis(course.toxicityScore);
        FHE.allowThis(course.qualityOfLifeScore);
        FHE.allowThis(patients[course.patientHash].treatmentResponseBps);
        // Update survival probability based on response
        ebool goodResponse = FHE.ge(response, FHE.asEuint64(7000));
        patients[course.patientHash].survivalProbBps = FHE.select(goodResponse,
            FHE.add(patients[course.patientHash].survivalProbBps, FHE.asEuint64(1000)),
            FHE.sub(patients[course.patientHash].survivalProbBps, FHE.asEuint64(500)));
        FHE.allowThis(patients[course.patientHash].survivalProbBps);
        emit TreatmentCompleted(courseId);
    }

    function allowResearchView(bytes32 patientHash, address coordinator) external {
        require(isResearchCoordinator[msg.sender], "Not coordinator");
        FHE.allow(patients[patientHash].biomarkerScore, coordinator);
        FHE.allow(patients[patientHash].survivalProbBps, coordinator);
        FHE.allow(patients[patientHash].treatmentResponseBps, coordinator);
        FHE.allow(patients[patientHash].trialEligibilityScore, coordinator);
    }
}
