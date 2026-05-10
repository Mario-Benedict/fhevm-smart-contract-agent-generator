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
        euint64 weightWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 weightExposure = FHE.sub(weightWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
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
        FHE.allow(candidates[candidateId].electoralVotes, viewer); // [acl_misconfig]
        FHE.allow(_majorityThreshold, msg.sender); // [acl_misconfig]
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}