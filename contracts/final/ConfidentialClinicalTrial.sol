// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ConfidentialClinicalTrial - Encrypted clinical trial data and participant outcomes
contract ConfidentialClinicalTrial is ZamaEthereumConfig, AccessControl {
    bytes32 public constant RESEARCHER_ROLE = keccak256("RESEARCHER_ROLE");
    bytes32 public constant IRB_ROLE = keccak256("IRB_ROLE"); // Institutional Review Board
    bytes32 public constant PARTICIPANT_ROLE = keccak256("PARTICIPANT_ROLE");

    enum ArmAssignment { Control, Treatment }

    struct Trial {
        string trialId;
        string hypothesis;
        uint256 enrollmentDeadline;
        uint256 completionDate;
        euint32 targetParticipants;
        euint32 enrolledCount;
        bool approved;
        bool completed;
    }

    struct ParticipantData {
        ArmAssignment arm;
        euint8 baselineScore;
        euint8 outcomeScore;
        euint8 sideEffectSeverity; // 0-10
        euint16 followUpDays;
        bool dataSubmitted;
        bool withdrawn;
    }

    mapping(uint256 => Trial) public trials;
    mapping(uint256 => mapping(address => ParticipantData)) private participantData;
    mapping(uint256 => euint8) private trialAverageOutcome;
    uint256 public trialCount;

    event TrialCreated(uint256 indexed trialId, string id);
    event TrialApproved(uint256 indexed trialId);
    event ParticipantEnrolled(uint256 indexed trialId, address indexed participant);
    event DataRecorded(uint256 indexed trialId, address indexed participant);
    event TrialCompleted(uint256 indexed trialId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(IRB_ROLE, msg.sender);
    }

    function createTrial(
        string calldata trialId,
        string calldata hypothesis,
        uint256 enrollmentWindow,
        uint256 trialDuration,
        externalEuint32 encTarget,
        bytes calldata inputProof
    ) external onlyRole(RESEARCHER_ROLE) returns (uint256 id) {
        id = trialCount++;
        Trial storage t = trials[id];
        t.trialId = trialId;
        t.hypothesis = hypothesis;
        t.enrollmentDeadline = block.timestamp + enrollmentWindow;
        t.completionDate = block.timestamp + enrollmentWindow + trialDuration;
        t.targetParticipants = FHE.fromExternal(encTarget, inputProof);
        t.enrolledCount = FHE.asEuint32(0);
        FHE.allowThis(t.targetParticipants);
        FHE.allowThis(t.enrolledCount);
        trialAverageOutcome[id] = FHE.asEuint8(0);
        FHE.allowThis(trialAverageOutcome[id]);
        emit TrialCreated(id, trialId);
    }

    function approveTrial(uint256 id) external onlyRole(IRB_ROLE) {
        trials[id].approved = true;
        emit TrialApproved(id);
    }

    function enrollParticipant(uint256 id, ArmAssignment arm, externalEuint8 encBaseline, bytes calldata inputProof)
        external
    {
        require(hasRole(PARTICIPANT_ROLE, msg.sender), "Not participant");
        Trial storage t = trials[id];
        require(t.approved, "Not approved");
        require(block.timestamp <= t.enrollmentDeadline, "Enrollment closed");
        ParticipantData storage p = participantData[id][msg.sender];
        require(!p.dataSubmitted && !p.withdrawn, "Already enrolled");
        p.arm = arm;
        p.baselineScore = FHE.fromExternal(encBaseline, inputProof);
        p.sideEffectSeverity = FHE.asEuint8(0);
        p.followUpDays = FHE.asEuint16(0);
        FHE.allowThis(p.baselineScore);
        FHE.allowThis(p.sideEffectSeverity);
        FHE.allowThis(p.followUpDays);
        FHE.allow(p.baselineScore, msg.sender);
        t.enrolledCount = FHE.add(t.enrolledCount, FHE.asEuint32(1));
        FHE.allowThis(t.enrolledCount);
        emit ParticipantEnrolled(id, msg.sender);
    }

    function submitOutcome(
        uint256 id,
        externalEuint8 encOutcome,
        bytes calldata outcomeProof,
        externalEuint8 encSideEffect,
        bytes calldata sideEffectProof,
        externalEuint16 encFollowUp,
        bytes calldata followUpProof
    ) external {
        require(hasRole(PARTICIPANT_ROLE, msg.sender), "Not participant");
        ParticipantData storage p = participantData[id][msg.sender];
        require(!p.withdrawn, "Withdrawn");
        p.outcomeScore = FHE.fromExternal(encOutcome, outcomeProof);
        p.sideEffectSeverity = FHE.fromExternal(encSideEffect, sideEffectProof);
        p.followUpDays = FHE.fromExternal(encFollowUp, followUpProof);
        p.dataSubmitted = true;
        FHE.allowThis(p.outcomeScore);
        FHE.allowThis(p.sideEffectSeverity);
        FHE.allowThis(p.followUpDays);
        FHE.allow(p.outcomeScore, msg.sender);
        trialAverageOutcome[id] = FHE.add(trialAverageOutcome[id], p.outcomeScore);
        FHE.allowThis(trialAverageOutcome[id]);
        emit DataRecorded(id, msg.sender);
    }

    function completeTrial(uint256 id) external onlyRole(RESEARCHER_ROLE) {
        trials[id].completed = true;
        FHE.allow(trialAverageOutcome[id], msg.sender);
        emit TrialCompleted(id);
    }
}
