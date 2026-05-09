// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title PrivateElectionCommission - National-scale encrypted election tally with multi-party verification
contract PrivateElectionCommission is ZamaEthereumConfig, AccessControl {
    bytes32 public constant COMMISSIONER_ROLE = keccak256("COMMISSIONER_ROLE");
    bytes32 public constant OBSERVER_ROLE     = keccak256("OBSERVER_ROLE");
    bytes32 public constant VOTER_ROLE        = keccak256("VOTER_ROLE");

    struct Candidate {
        string  name;
        string  party;
        euint64 voteCount;
        bool    active;
    }

    struct Election {
        string   title;
        uint256  startTime;
        uint256  endTime;
        uint8    candidateCount;
        euint64  totalVotesCast;
        bool     resultsPublished;
        bool     active;
    }

    mapping(uint256 => Election) public elections;
    mapping(uint256 => mapping(uint8 => Candidate)) public candidates;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => euint8) public voterIdHash;  // encrypted voter credential
    uint256 public electionCount;

    event ElectionCreated(uint256 indexed electionId, string title);
    event CandidateAdded(uint256 indexed electionId, uint8 index, string name);
    event VoteCast(uint256 indexed electionId, address indexed voter);
    event ResultsPublished(uint256 indexed electionId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE,  msg.sender);
        _grantRole(COMMISSIONER_ROLE,   msg.sender);
    }

    function registerVoter(address voter, externalEuint8 calldata encId, bytes calldata inputProof)
        external onlyRole(COMMISSIONER_ROLE)
    {
        voterIdHash[voter] = FHE.fromExternal(encId, inputProof);
        _grantRole(VOTER_ROLE, voter);
        FHE.allowThis(voterIdHash[voter]);
        FHE.allow(voterIdHash[voter], voter);
    }

    function createElection(string calldata title, uint256 startDelay, uint256 duration)
        external onlyRole(COMMISSIONER_ROLE) returns (uint256 electionId)
    {
        electionId = electionCount++;
        Election storage e = elections[electionId];
        e.title       = title;
        e.startTime   = block.timestamp + startDelay;
        e.endTime     = block.timestamp + startDelay + duration;
        e.totalVotesCast = FHE.asEuint64(0);
        e.active      = true;
        FHE.allowThis(e.totalVotesCast);
        emit ElectionCreated(electionId, title);
    }

    function addCandidate(uint256 electionId, string calldata name, string calldata party)
        external onlyRole(COMMISSIONER_ROLE)
    {
        Election storage e = elections[electionId];
        require(block.timestamp < e.startTime, "Election started");
        uint8 idx = e.candidateCount++;
        Candidate storage c = candidates[electionId][idx];
        c.name     = name;
        c.party    = party;
        c.voteCount = FHE.asEuint64(0);
        c.active   = true;
        FHE.allowThis(c.voteCount);
        emit CandidateAdded(electionId, idx, name);
    }

    function castVote(uint256 electionId, externalEuint8 calldata encChoice, bytes calldata inputProof)
        external onlyRole(VOTER_ROLE)
    {
        require(!hasVoted[electionId][msg.sender], "Already voted");
        Election storage e = elections[electionId];
        require(block.timestamp >= e.startTime && block.timestamp <= e.endTime, "Not active");

        euint8 choice = FHE.fromExternal(encChoice, inputProof);
        // Tally encrypted vote across all candidates using select
        for (uint8 i = 0; i < e.candidateCount; i++) {
            ebool selected = FHE.eq(choice, FHE.asEuint8(i));
            candidates[electionId][i].voteCount = FHE.add(
                candidates[electionId][i].voteCount,
                FHE.select(selected, FHE.asEuint64(1), FHE.asEuint64(0))
            );
            FHE.allowThis(candidates[electionId][i].voteCount);
        }
        e.totalVotesCast = FHE.add(e.totalVotesCast, FHE.asEuint64(1));
        FHE.allowThis(e.totalVotesCast);
        hasVoted[electionId][msg.sender] = true;
        emit VoteCast(electionId, msg.sender);
    }

    function publishResults(uint256 electionId) external onlyRole(COMMISSIONER_ROLE) {
        Election storage e = elections[electionId];
        require(block.timestamp > e.endTime, "Not ended");
        require(!e.resultsPublished, "Already published");
        e.resultsPublished = true;
        for (uint8 i = 0; i < e.candidateCount; i++) {
            FHE.allow(candidates[electionId][i].voteCount, msg.sender);
        }
        FHE.allow(e.totalVotesCast, msg.sender);
        // Grant observers read access
        emit ResultsPublished(electionId);
    }

    function grantObserverAccess(uint256 electionId, address observer)
        external onlyRole(COMMISSIONER_ROLE)
    {
        Election storage e = elections[electionId];
        require(e.resultsPublished, "Not published");
        for (uint8 i = 0; i < e.candidateCount; i++) {
            FHE.allow(candidates[electionId][i].voteCount, observer);
        }
    }
}
