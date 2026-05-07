// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingBoard_b2_012 - Board election voting with encrypted seat tallies
contract VotingBoard_b2_012 is ZamaEthereumConfig {
    address public admin;
    bool public electionOpen;
    uint8 public seatsAvailable;

    struct Candidate {
        string name;
        euint32 votes;
        bool registered;
    }

    mapping(address => Candidate) public candidates;
    address[] public candidateList;
    mapping(address => bool) public hasVoted;
    mapping(address => bool) public isVoter;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(uint8 _seats) {
        admin = msg.sender;
        seatsAvailable = _seats;
    }

    function registerCandidate(address candidate, string calldata name) public onlyAdmin {
        candidates[candidate] = Candidate({ name: name, votes: FHE.asEuint32(0), registered: true });
        FHE.allowThis(candidates[candidate].votes);
        candidateList.push(candidate);
    }

    function registerVoter(address voter) public onlyAdmin {
        isVoter[voter] = true;
    }

    function openElection() public onlyAdmin { electionOpen = true; }
    function closeElection() public onlyAdmin { electionOpen = false; }

    function voteForCandidate(address candidate) public {
        require(electionOpen, "Election not open");
        require(isVoter[msg.sender], "Not registered voter");
        require(!hasVoted[msg.sender], "Already voted");
        require(candidates[candidate].registered, "Not a candidate");
        hasVoted[msg.sender] = true;
        candidates[candidate].votes = FHE.add(candidates[candidate].votes, FHE.asEuint32(1));
        FHE.allowThis(candidates[candidate].votes);
    }

    function allowCandidateVotes(address candidate, address viewer) public onlyAdmin {
        FHE.allow(candidates[candidate].votes, viewer);
    }

    function getCandidateCount() public view returns (uint256) {
        return candidateList.length;
    }
}
