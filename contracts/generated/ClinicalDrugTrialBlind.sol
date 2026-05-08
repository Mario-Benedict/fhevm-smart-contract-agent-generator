// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ClinicalDrugTrialBlind
/// @notice Double-blind clinical trial where patient group assignments (control/treatment)
///         remain encrypted. Trial endpoints and outcomes collected privately.
///         IRB can decrypt aggregate results without revealing individual assignments.
contract ClinicalDrugTrialBlind is ZamaEthereumConfig, Ownable {
    enum TrialPhase { Enrollment, Active, Followup, Completed }

    struct Patient {
        euint8 groupAssignment;    // encrypted 0=control, 1=treatment
        euint8 baselineScore;      // encrypted baseline clinical score
        euint8 endpointScore;      // encrypted post-treatment score
        euint8 adverseEvents;      // encrypted count of adverse events
        bool enrolled;
        bool completed;
    }

    struct Trial {
        string drugName;
        string phase;
        euint32 controlGroupSize;
        euint32 treatmentGroupSize;
        euint64 avgBaselineControl;
        euint64 avgBaselineTreatment;
        TrialPhase status;
        uint256 startDate;
        uint256 endDate;
    }

    mapping(uint256 => Trial) private trials;
    mapping(uint256 => mapping(address => Patient)) private patients;
    mapping(address => bool) public isClinician;
    mapping(address => bool) public isIRB;
    uint256 public trialCount;

    event TrialCreated(uint256 indexed id, string drug);
    event PatientEnrolled(uint256 indexed trialId, address patient);
    event OutcomeRecorded(uint256 indexed trialId, address patient);
    event TrialCompleted(uint256 indexed id);

    modifier onlyClinician() {
        require(isClinician[msg.sender] || msg.sender == owner(), "Not clinician");
        _;
    }

    constructor() Ownable(msg.sender) {
        isClinician[msg.sender] = true;
        isIRB[msg.sender] = true;
    }

    function addClinician(address c) external onlyOwner { isClinician[c] = true; }
    function addIRB(address irb) external onlyOwner { isIRB[irb] = true; }

    function createTrial(string calldata drug, string calldata phase, uint256 durationDays)
        external onlyClinician returns (uint256 id)
    {
        id = trialCount++;
        trials[id] = Trial({
            drugName: drug, phase: phase,
            controlGroupSize: FHE.asEuint32(0), treatmentGroupSize: FHE.asEuint32(0),
            avgBaselineControl: FHE.asEuint64(0), avgBaselineTreatment: FHE.asEuint64(0),
            status: TrialPhase.Enrollment,
            startDate: block.timestamp, endDate: block.timestamp + durationDays * 1 days
        });
        FHE.allowThis(trials[id].controlGroupSize);
        FHE.allowThis(trials[id].treatmentGroupSize);
        FHE.allowThis(trials[id].avgBaselineControl);
        FHE.allowThis(trials[id].avgBaselineTreatment);
        emit TrialCreated(id, drug);
    }

    function enrollPatient(
        uint256 trialId,
        address patient,
        externalEuint8 encGroup, bytes calldata gProof,
        externalEuint8 encBaseline, bytes calldata bProof
    ) external onlyClinician {
        require(trials[trialId].status == TrialPhase.Enrollment, "Not enrolling");
        euint8 group = FHE.fromExternal(encGroup, gProof);
        euint8 baseline = FHE.fromExternal(encBaseline, bProof);
        patients[trialId][patient] = Patient({
            groupAssignment: group, baselineScore: baseline,
            endpointScore: FHE.asEuint8(0), adverseEvents: FHE.asEuint8(0),
            enrolled: true, completed: false
        });
        FHE.allowThis(patients[trialId][patient].groupAssignment);
        // group only revealed to IRB, not patient
        FHE.allow(patients[trialId][patient].groupAssignment, isIRB[msg.sender] ? msg.sender : owner());
        FHE.allowThis(patients[trialId][patient].baselineScore);
        FHE.allow(patients[trialId][patient].baselineScore, patient);
        FHE.allowThis(patients[trialId][patient].endpointScore);
        FHE.allowThis(patients[trialId][patient].adverseEvents);
        // Update group counters
        ebool isControl = FHE.eq(group, FHE.asEuint8(0));
        trials[trialId].controlGroupSize = FHE.select(isControl,
            FHE.add(trials[trialId].controlGroupSize, FHE.asEuint32(1)),
            trials[trialId].controlGroupSize);
        trials[trialId].treatmentGroupSize = FHE.select(isControl,
            trials[trialId].treatmentGroupSize,
            FHE.add(trials[trialId].treatmentGroupSize, FHE.asEuint32(1)));
        FHE.allowThis(trials[trialId].controlGroupSize);
        FHE.allowThis(trials[trialId].treatmentGroupSize);
        emit PatientEnrolled(trialId, patient);
    }

    function recordOutcome(
        uint256 trialId,
        address patient,
        externalEuint8 encEndpoint, bytes calldata eProof,
        externalEuint8 encAdverse, bytes calldata aProof
    ) external onlyClinician {
        require(patients[trialId][patient].enrolled && !patients[trialId][patient].completed, "Invalid");
        patients[trialId][patient].endpointScore = FHE.fromExternal(encEndpoint, eProof);
        patients[trialId][patient].adverseEvents = FHE.fromExternal(encAdverse, aProof);
        patients[trialId][patient].completed = true;
        FHE.allowThis(patients[trialId][patient].endpointScore);
        FHE.allow(patients[trialId][patient].endpointScore, patient);
        FHE.allowThis(patients[trialId][patient].adverseEvents);
        FHE.allow(patients[trialId][patient].adverseEvents, patient);
        emit OutcomeRecorded(trialId, patient);
    }

    function completeTrial(uint256 trialId) external onlyClinician {
        trials[trialId].status = TrialPhase.Completed;
        emit TrialCompleted(trialId);
    }

    function allowTrialAggregate(uint256 trialId, address viewer) external {
        require(isIRB[msg.sender], "Not IRB");
        FHE.allow(trials[trialId].controlGroupSize, viewer);
        FHE.allow(trials[trialId].treatmentGroupSize, viewer);
    }

    function allowPatientRecord(uint256 trialId, address patient, address viewer) external {
        require(isIRB[msg.sender], "Not IRB");
        FHE.allow(patients[trialId][patient].groupAssignment, viewer);
        FHE.allow(patients[trialId][patient].baselineScore, viewer);
        FHE.allow(patients[trialId][patient].endpointScore, viewer);
        FHE.allow(patients[trialId][patient].adverseEvents, viewer);
    }
}
