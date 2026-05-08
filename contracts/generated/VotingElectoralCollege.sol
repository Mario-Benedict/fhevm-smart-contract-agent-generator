// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingElectoralCollege
/// @notice Electoral college voting where each delegate carries encrypted vote weight.
///         State allocations remain hidden until tally. Winner declared when encrypted
///         total surpasses encrypted majority threshold.
contract VotingElectoralCollege is ZamaEthereumConfig, Ownable {
    struct Candidate {
        string name;
        euint32 electoralVotes;
    }

    struct Delegate {
        euint32 electoralWeight;
        bool hasVoted;
        bool isDelegate;
    }

    mapping(uint256 => Candidate) public candidates;
    uint256 public candidateCount;
    mapping(address => Delegate) private delegates;
    euint32 private _majorityThreshold;
    bool public electionOpen;
    bool public resultsFinalized;

    event DelegateRegistered(address indexed d);
    event VoteCast(address indexed delegate, uint256 candidateId);
    event ElectionClosed();

    constructor(euint32 threshold) Ownable(msg.sender) {
        _majorityThreshold = threshold;
        FHE.allowThis(_majorityThreshold);
        electionOpen = false;
        resultsFinalized = false;
    }

    function addCandidate(string calldata name) external onlyOwner {
        candidates[candidateCount] = Candidate({
            name: name,
            electoralVotes: FHE.asEuint32(0)
        });
        FHE.allowThis(candidates[candidateCount].electoralVotes);
        candidateCount++;
    }

    function registerDelegate(address d, externalEuint32 encWeight, bytes calldata proof) external onlyOwner {
        euint32 weight = FHE.fromExternal(encWeight, proof);
        delegates[d].electoralWeight = weight;
        delegates[d].hasVoted = false;
        delegates[d].isDelegate = true;
        FHE.allowThis(delegates[d].electoralWeight);
        emit DelegateRegistered(d);
    }

    function openElection() external onlyOwner { electionOpen = true; }
    function closeElection() external onlyOwner {
        electionOpen = false;
        resultsFinalized = true;
        emit ElectionClosed();
    }

    function vote(uint256 candidateId) external {
        require(electionOpen, "Not open");
        require(delegates[msg.sender].isDelegate, "Not delegate");
        require(!delegates[msg.sender].hasVoted, "Already voted");
        require(candidateId < candidateCount, "Invalid candidate");
        candidates[candidateId].electoralVotes = FHE.add(
            candidates[candidateId].electoralVotes,
            delegates[msg.sender].electoralWeight
        );
        delegates[msg.sender].hasVoted = true;
        FHE.allowThis(candidates[candidateId].electoralVotes);
        emit VoteCast(msg.sender, candidateId);
    }

    function hasWinner(uint256 candidateId) external view returns (bool) {
        require(resultsFinalized, "Not finalized");
        return FHE.isInitialized(candidates[candidateId].electoralVotes);
    }

    function allowCandidateVotes(uint256 candidateId, address viewer) external onlyOwner {
        FHE.allow(candidates[candidateId].electoralVotes, viewer);
    }
}
