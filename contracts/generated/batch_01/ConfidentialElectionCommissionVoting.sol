// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialElectionCommissionVoting
/// @notice National election commission system with encrypted vote tallies per candidate,
///         encrypted voter eligibility scores, confidential district allocations, and
///         cryptographic audit trail without revealing individual votes.
contract ConfidentialElectionCommissionVoting is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ElectionType { PRESIDENTIAL, PARLIAMENTARY, REFERENDUM, LOCAL_COUNCIL, JUDICIAL }
    enum VoterStatus { UNREGISTERED, REGISTERED, VOTED, INVALIDATED }

    struct Election {
        string electionName;
        string jurisdiction;
        ElectionType elecType;
        uint256 registrationDeadline;
        uint256 votingStart;
        uint256 votingEnd;
        uint256 totalRegisteredVoters;
        euint32 totalVotesCast;         // encrypted running total
        euint8  participationRateBps;   // encrypted turnout
        bool resultsSealed;
        bool audited;
    }

    struct Candidate {
        string fullName;
        string party;
        string district;
        euint64 voteCount;             // encrypted vote tally
        euint32 districtDelegates;     // encrypted electoral college weight
        bool disqualified;
    }

    struct VoterRecord {
        euint8  eligibilityScore;      // encrypted 0-100 eligibility
        euint8  biometricVerified;     // encrypted verification flag
        euint32 districtCode;          // encrypted district assignment
        VoterStatus status;
        uint256 registrationDate;
        bool identityVerified;
    }

    mapping(uint256 => Election) private elections;
    mapping(uint256 => mapping(uint256 => Candidate)) private candidates; // elecId => candId => Candidate
    mapping(uint256 => uint256) private candidateCounts;
    mapping(address => VoterRecord) private voterRegistry;
    mapping(uint256 => mapping(address => bool)) private hasVoted;
    mapping(address => bool) public isElectionOfficer;
    mapping(address => bool) public isAuditor;
    uint256 public electionCount;
    euint64 private _totalNationalVotes;

    event ElectionCreated(uint256 indexed elecId, ElectionType eType);
    event CandidateRegistered(uint256 indexed elecId, uint256 candId, string name);
    event VoterRegistered(address indexed voter);
    event VoteCast(uint256 indexed elecId, address indexed voter);
    event ResultsSealed(uint256 indexed elecId);
    event ElectionAudited(uint256 indexed elecId);

    constructor() Ownable(msg.sender) {
        _totalNationalVotes = FHE.asEuint64(0);
        FHE.allowThis(_totalNationalVotes);
        isElectionOfficer[msg.sender] = true;
        isAuditor[msg.sender] = true;
    }

    function addElectionOfficer(address officer) external onlyOwner { isElectionOfficer[officer] = true; }
    function addAuditor(address aud) external onlyOwner { isAuditor[aud] = true; }

    function createElection(
        string calldata name,
        string calldata jurisdiction,
        ElectionType eType,
        uint256 regDeadline,
        uint256 votingStart,
        uint256 votingEnd
    ) external returns (uint256 elecId) {
        require(isElectionOfficer[msg.sender], "Not officer");
        elecId = electionCount++;
        elections[elecId].electionName = name;
        elections[elecId].jurisdiction = jurisdiction;
        elections[elecId].elecType = eType;
        elections[elecId].registrationDeadline = regDeadline;
        elections[elecId].votingStart = votingStart;
        elections[elecId].votingEnd = votingEnd;
        elections[elecId].totalRegisteredVoters = 0;
        elections[elecId].totalVotesCast = FHE.asEuint32(0);
        elections[elecId].participationRateBps = FHE.asEuint8(0);
        elections[elecId].resultsSealed = false;
        elections[elecId].audited = false;
        FHE.allowThis(elections[elecId].totalVotesCast);
        FHE.allowThis(elections[elecId].participationRateBps);
        emit ElectionCreated(elecId, eType);
    }

    function registerCandidate(
        uint256 elecId,
        string calldata name,
        string calldata party,
        string calldata district,
        externalEuint32 encDelegates, bytes calldata proof
    ) external returns (uint256 candId) {
        require(isElectionOfficer[msg.sender], "Not officer");
        euint32 delegates = FHE.fromExternal(encDelegates, proof);
        candId = candidateCounts[elecId]++;
        candidates[elecId][candId] = Candidate({
            fullName: name,
            party: party,
            district: district,
            voteCount: FHE.asEuint64(0),
            districtDelegates: delegates,
            disqualified: false
        });
        FHE.allowThis(candidates[elecId][candId].voteCount);
        FHE.allowThis(candidates[elecId][candId].districtDelegates);
        emit CandidateRegistered(elecId, candId, name);
    }

    function registerVoter(
        address voter,
        externalEuint8  encEligScore,  bytes calldata esProof,
        externalEuint8  encBiometric,  bytes calldata bmProof,
        externalEuint32 encDistrict,   bytes calldata dProof
    ) external {
        require(isElectionOfficer[msg.sender], "Not officer");
        require(voterRegistry[voter].status == VoterStatus.UNREGISTERED, "Already registered");
        euint8  elig     = FHE.fromExternal(encEligScore, esProof);
        euint8  biometric = FHE.fromExternal(encBiometric, bmProof);
        euint32 district = FHE.fromExternal(encDistrict, dProof);
        voterRegistry[voter] = VoterRecord({
            eligibilityScore: elig,
            biometricVerified: biometric,
            districtCode: district,
            status: VoterStatus.REGISTERED,
            registrationDate: block.timestamp,
            identityVerified: true
        });
        FHE.allowThis(voterRegistry[voter].eligibilityScore);
        FHE.allow(voterRegistry[voter].eligibilityScore, voter);
        FHE.allowThis(voterRegistry[voter].biometricVerified);
        FHE.allowThis(voterRegistry[voter].districtCode);
        emit VoterRegistered(voter);
    }

    function castVote(
        uint256 elecId,
        uint256 candId
    ) external nonReentrant {
        require(block.timestamp >= elections[elecId].votingStart, "Voting not started");
        require(block.timestamp <= elections[elecId].votingEnd, "Voting ended");
        require(voterRegistry[msg.sender].status == VoterStatus.REGISTERED, "Not eligible");
        require(!hasVoted[elecId][msg.sender], "Already voted");
        require(!candidates[elecId][candId].disqualified, "Candidate disqualified");
        hasVoted[elecId][msg.sender] = true;
        voterRegistry[msg.sender].status = VoterStatus.VOTED;
        // Add encrypted vote — count increments by 1 privately
        candidates[elecId][candId].voteCount = FHE.add(
            candidates[elecId][candId].voteCount, FHE.asEuint64(1)
        );
        elections[elecId].totalVotesCast = FHE.add(
            elections[elecId].totalVotesCast, FHE.asEuint32(1)
        );
        elections[elecId].totalRegisteredVoters++;
        _totalNationalVotes = FHE.add(_totalNationalVotes, FHE.asEuint64(1));
        FHE.allowThis(candidates[elecId][candId].voteCount);
        FHE.allowThis(elections[elecId].totalVotesCast);
        FHE.allowThis(_totalNationalVotes);
        emit VoteCast(elecId, msg.sender);
    }

    function sealResults(uint256 elecId) external {
        require(isElectionOfficer[msg.sender], "Not officer");
        require(block.timestamp > elections[elecId].votingEnd, "Voting still active");
        elections[elecId].resultsSealed = true;
        emit ResultsSealed(elecId);
    }

    function auditElection(uint256 elecId) external {
        require(isAuditor[msg.sender], "Not auditor");
        elections[elecId].audited = true;
        emit ElectionAudited(elecId);
    }

    function disqualifyCandidate(uint256 elecId, uint256 candId) external {
        require(isElectionOfficer[msg.sender], "Not officer");
        candidates[elecId][candId].disqualified = true;
    }

    function allowResultsView(uint256 elecId, uint256 candId, address viewer) external onlyOwner {
        require(elections[elecId].resultsSealed, "Results not sealed");
        FHE.allow(candidates[elecId][candId].voteCount, viewer);
    }

    function allowElectionStats(uint256 elecId, address viewer) external onlyOwner {
        FHE.allow(elections[elecId].totalVotesCast, viewer);
        FHE.allow(elections[elecId].participationRateBps, viewer);
    }
}
