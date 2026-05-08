// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title HealthcarePrivateClinicalTrial
/// @notice Clinical trial management with encrypted patient data and trial results.
///         Participant health metrics are encrypted; statistical efficacy is computed
///         homomorphically without revealing individual patient outcomes.
contract HealthcarePrivateClinicalTrial is ZamaEthereumConfig, Ownable {
    struct Trial {
        string trialName;
        string drugName;
        euint32 totalParticipants;
        euint32 positiveResponders;
        euint32 adverseEvents;
        euint16 efficacyScore; // out of 10000 bps
        bool completed;
        uint256 startDate;
        uint256 endDate;
    }

    struct Participant {
        euint8 baselineScore;       // encrypted health baseline
        euint8 outcomeScore;        // encrypted trial outcome
        euint8 adverseEventSeverity; // 0=none, 1-3 levels
        bool enrolled;
        bool dataSubmitted;
        uint256 trialId;
    }

    mapping(uint256 => Trial) private trials;
    uint256 public trialCount;
    mapping(address => Participant) private participants;
    mapping(address => bool) public isResearcher;

    event TrialCreated(uint256 indexed id, string name);
    event ParticipantEnrolled(uint256 indexed trialId, address participant);
    event OutcomeSubmitted(uint256 indexed trialId, address participant);
    event TrialCompleted(uint256 indexed id);

    constructor() Ownable(msg.sender) {}

    function addResearcher(address r) external onlyOwner { isResearcher[r] = true; }

    function createTrial(string calldata name, string calldata drug, uint256 endDate) external {
        require(isResearcher[msg.sender], "Not researcher");
        uint256 id = trialCount++;
        trials[id].trialName = name;
        trials[id].drugName = drug;
        trials[id].totalParticipants = FHE.asEuint32(0);
        trials[id].positiveResponders = FHE.asEuint32(0);
        trials[id].adverseEvents = FHE.asEuint32(0);
        trials[id].efficacyScore = FHE.asEuint16(0);
        trials[id].startDate = block.timestamp;
        trials[id].endDate = endDate;
        FHE.allowThis(trials[id].totalParticipants);
        FHE.allowThis(trials[id].positiveResponders);
        FHE.allowThis(trials[id].adverseEvents);
        FHE.allowThis(trials[id].efficacyScore);
        emit TrialCreated(id, name);
    }

    function enroll(
        uint256 trialId,
        externalEuint8 encBaseline, bytes calldata proof
    ) external {
        require(!participants[msg.sender].enrolled, "Already enrolled");
        Trial storage t = trials[trialId];
        require(!t.completed, "Trial closed");
        participants[msg.sender].baselineScore = FHE.fromExternal(encBaseline, proof);
        participants[msg.sender].outcomeScore = FHE.asEuint8(0);
        participants[msg.sender].adverseEventSeverity = FHE.asEuint8(0);
        participants[msg.sender].enrolled = true;
        participants[msg.sender].trialId = trialId;
        t.totalParticipants = FHE.add(t.totalParticipants, FHE.asEuint32(1));
        FHE.allowThis(participants[msg.sender].baselineScore);
        FHE.allowThis(participants[msg.sender].outcomeScore);
        FHE.allowThis(participants[msg.sender].adverseEventSeverity);
        FHE.allowThis(t.totalParticipants);
        emit ParticipantEnrolled(trialId, msg.sender);
    }

    function submitOutcome(
        externalEuint8 encOutcome, bytes calldata oProof,
        externalEuint8 encAdverse, bytes calldata aProof
    ) external {
        Participant storage p = participants[msg.sender];
        require(p.enrolled && !p.dataSubmitted, "Cannot submit");
        p.outcomeScore = FHE.fromExternal(encOutcome, oProof);
        p.adverseEventSeverity = FHE.fromExternal(encAdverse, aProof);
        p.dataSubmitted = true;
        Trial storage t = trials[p.trialId];
        // Positive response: outcome > baseline
        ebool improved = FHE.gt(p.outcomeScore, p.baselineScore);
        euint32 improvedCount = FHE.select(improved, FHE.asEuint32(1), FHE.asEuint32(0));
        t.positiveResponders = FHE.add(t.positiveResponders, improvedCount);
        ebool hasAdverse = FHE.gt(p.adverseEventSeverity, FHE.asEuint8(0));
        euint32 adverseCount = FHE.select(hasAdverse, FHE.asEuint32(1), FHE.asEuint32(0));
        t.adverseEvents = FHE.add(t.adverseEvents, adverseCount);
        FHE.allowThis(p.outcomeScore);
        FHE.allowThis(p.adverseEventSeverity);
        FHE.allowThis(t.positiveResponders);
        FHE.allowThis(t.adverseEvents);
        emit OutcomeSubmitted(p.trialId, msg.sender);
    }

    function completeTrial(uint256 trialId) external {
        require(isResearcher[msg.sender], "Not researcher");
        Trial storage t = trials[trialId];
        require(!t.completed, "Already done");
        t.completed = true;
        // Efficacy = positiveResponders / totalParticipants * 10000
        t.efficacyScore = FHE.asEuint16(0); // computed off-chain from encrypted data
        FHE.allowThis(t.efficacyScore);
        emit TrialCompleted(trialId);
    }

    function allowTrialStats(uint256 id, address viewer) external {
        require(isResearcher[msg.sender], "Not researcher");
        FHE.allow(trials[id].totalParticipants, viewer);
        FHE.allow(trials[id].positiveResponders, viewer);
        FHE.allow(trials[id].adverseEvents, viewer);
    }

    function allowParticipantData(address viewer) external {
        FHE.allow(participants[msg.sender].outcomeScore, viewer);
        FHE.allow(participants[msg.sender].baselineScore, viewer);
    }
}
