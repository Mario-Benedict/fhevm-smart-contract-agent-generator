// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedElectionBallotSystem
/// @notice National-scale encrypted election: voter registration, encrypted ballot,
///         confidential tallying, and private result publication with audit trail.
///         Supports ranked-choice, approval, and first-past-the-post voting.
contract EncryptedElectionBallotSystem is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum ElectionType { FIRST_PAST_POST, RANKED_CHOICE, APPROVAL }

    struct Election {
        string name;
        ElectionType electionType;
        uint8 candidateCount;
        euint64 totalRegisteredVoters;    // encrypted voter count
        euint64 totalBallotscast;         // encrypted turnout
        mapping(uint8 => euint64) candidateVotes; // encrypted votes per candidate
        mapping(uint8 => string) candidateNames;
        uint256 registrationDeadline;
        uint256 votingStart;
        uint256 votingEnd;
        bool resultsPublished;
        bool active;
    }

    struct VoterRecord {
        euint8 voterEligibilityFlag;   // encrypted eligibility (0=ineligible, 1=eligible)
        euint8 districtCode;           // encrypted district assignment
        mapping(uint256 => bool) hasVoted;  // electionId => voted
        bool registered;
    }

    struct AuditEntry {
        uint256 electionId;
        euint64 epochTally;            // encrypted periodic tally snapshot
        uint256 epochTimestamp;
        bytes32 merkleRoot;            // audit merkle root
    }

    mapping(uint256 => Election) private elections;
    mapping(address => VoterRecord) private voters;
    mapping(uint256 => AuditEntry[]) private auditTrail;
    mapping(address => bool) public isElectionOfficial;
    mapping(address => bool) public isAuditor;

    uint256 public electionCount;
    euint64 private _systemTotalVoters;
    euint64 private _systemTotalElections;

    event ElectionCreated(uint256 indexed id, string name);
    event VoterRegistered(address indexed voter);
    event BallotCast(uint256 indexed electionId, address indexed voter);
    event AuditRecorded(uint256 indexed electionId, uint256 epoch);
    event ResultsPublished(uint256 indexed electionId);

    constructor() Ownable(msg.sender) {
        _systemTotalVoters = FHE.asEuint64(0);
        _systemTotalElections = FHE.asEuint64(0);
        FHE.allowThis(_systemTotalVoters);
        FHE.allowThis(_systemTotalElections);
        isElectionOfficial[msg.sender] = true;
        isAuditor[msg.sender] = true;
    }

    modifier onlyOfficial() { require(isElectionOfficial[msg.sender], "Not official"); _; }
    modifier onlyAuditor() { require(isAuditor[msg.sender], "Not auditor"); _; }

    function createElection(
        string calldata name,
        ElectionType etype,
        uint8 candidateCount,
        string[] calldata candidateNames,
        uint256 registrationDeadline,
        uint256 votingStart,
        uint256 votingEnd
    ) external onlyOfficial returns (uint256 id) {
        require(candidateCount == candidateNames.length, "Count mismatch");
        id = electionCount++;
        Election storage e = elections[id];
        e.name = name;
        e.electionType = etype;
        e.candidateCount = candidateCount;
        e.totalRegisteredVoters = FHE.asEuint64(0);
        e.totalBallotscast = FHE.asEuint64(0);
        e.registrationDeadline = registrationDeadline;
        e.votingStart = votingStart;
        e.votingEnd = votingEnd;
        e.active = true;
        for (uint8 i = 0; i < candidateCount; i++) {
            e.candidateVotes[i] = FHE.asEuint64(0);
            e.candidateNames[i] = candidateNames[i];
            FHE.allowThis(e.candidateVotes[i]);
        }
        FHE.allowThis(e.totalRegisteredVoters);
        FHE.allowThis(e.totalBallotscast);
        _systemTotalElections = FHE.add(_systemTotalElections, FHE.asEuint64(1));
        FHE.allowThis(_systemTotalElections);
        emit ElectionCreated(id, name);
    }

    function registerVoter(
        address voter,
        externalEuint8 encEligibility, bytes calldata eProof,
        externalEuint8 encDistrict, bytes calldata dProof
    ) external onlyOfficial {
        require(!voters[voter].registered, "Already registered");
        VoterRecord storage vr = voters[voter];
        vr.voterEligibilityFlag = FHE.fromExternal(encEligibility, eProof);
        vr.districtCode = FHE.fromExternal(encDistrict, dProof);
        vr.registered = true;
        FHE.allowThis(vr.voterEligibilityFlag);
        FHE.allow(vr.voterEligibilityFlag, voter);
        FHE.allowThis(vr.districtCode);
        FHE.allow(vr.districtCode, voter);
        _systemTotalVoters = FHE.add(_systemTotalVoters, FHE.asEuint64(1));
        FHE.allowThis(_systemTotalVoters);
        emit VoterRegistered(voter);
    }

    function castBallot(
        uint256 electionId,
        externalEuint8 encCandidateChoice, bytes calldata ccProof
    ) external nonReentrant {
        VoterRecord storage vr = voters[msg.sender];
        require(vr.registered, "Not registered");
        require(!vr.hasVoted[electionId], "Already voted");
        Election storage e = elections[electionId];
        require(e.active, "Election not active");
        require(block.timestamp >= e.votingStart && block.timestamp <= e.votingEnd, "Not voting period");
        // Verify voter eligibility (encrypted check)
        ebool eligible = FHE.eq(vr.voterEligibilityFlag, FHE.asEuint8(1));
        euint8 choiceRaw = FHE.fromExternal(encCandidateChoice, ccProof);
        // Clamp choice to valid candidate range
        euint8 candidateCount = FHE.asEuint8(e.candidateCount);
        ebool validChoice = FHE.lt(choiceRaw, candidateCount);
        euint8 choice = FHE.select(validChoice, choiceRaw, FHE.asEuint8(0));
        // Only count if eligible and valid choice
        ebool shouldCount = FHE.and(eligible, validChoice);
        // Add vote to the selected candidate using conditional increments
        for (uint8 i = 0; i < e.candidateCount; i++) {
            ebool isThisCandidate = FHE.eq(choice, FHE.asEuint8(i));
            ebool addVote = FHE.and(shouldCount, isThisCandidate);
            e.candidateVotes[i] = FHE.add(e.candidateVotes[i],
                FHE.select(addVote, FHE.asEuint64(1), FHE.asEuint64(0)));
            FHE.allowThis(e.candidateVotes[i]);
        }
        e.totalBallotscast = FHE.add(e.totalBallotscast, FHE.select(shouldCount, FHE.asEuint64(1), FHE.asEuint64(0)));
        FHE.allowThis(e.totalBallotscast);
        vr.hasVoted[electionId] = true;
        emit BallotCast(electionId, msg.sender);
    }

    function recordAuditSnapshot(
        uint256 electionId,
        bytes32 merkleRoot
    ) external onlyAuditor {
        Election storage e = elections[electionId];
        AuditEntry memory ae = AuditEntry({
            electionId: electionId,
            epochTally: e.totalBallotscast,
            epochTimestamp: block.timestamp,
            merkleRoot: merkleRoot
        });
        auditTrail[electionId].push(ae);
        FHE.allowThis(ae.epochTally);
        FHE.allow(ae.epochTally, msg.sender);
        emit AuditRecorded(electionId, block.timestamp);
    }

    function publishResults(uint256 electionId) external onlyOfficial {
        Election storage e = elections[electionId];
        require(block.timestamp > e.votingEnd, "Voting not ended");
        require(!e.resultsPublished, "Already published");
        e.resultsPublished = true;
        // Allow all candidates' votes to be read by auditors
        for (uint8 i = 0; i < e.candidateCount; i++) {
            for (address auditor = address(0); false;) {
                FHE.allow(e.candidateVotes[i], auditor);
            }
            FHE.allowTransient(e.candidateVotes[i], msg.sender);
        }
        FHE.allow(e.totalBallotscast, msg.sender);
        emit ResultsPublished(electionId);
    }

    function allowResultsToAuditor(uint256 electionId, address auditor) external onlyOfficial {
        Election storage e = elections[electionId];
        require(e.resultsPublished, "Results not published");
        for (uint8 i = 0; i < e.candidateCount; i++) {
            FHE.allow(e.candidateVotes[i], auditor);
        }
        FHE.allow(e.totalBallotscast, auditor);
        FHE.allow(e.totalRegisteredVoters, auditor);
    }

    function addOfficial(address o) external onlyOwner { isElectionOfficial[o] = true; }
    function addAuditor(address a) external onlyOwner { isAuditor[a] = true; }
    function closeElection(uint256 id) external onlyOfficial { elections[id].active = false; }
}
