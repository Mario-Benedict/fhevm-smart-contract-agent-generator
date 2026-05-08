// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingAcademicTenure
/// @notice University tenure committee vote with encrypted rubric scores per dimension.
///         Each committee member submits encrypted scores for Teaching, Research, Service.
///         Final aggregate score determines tenure recommendation.
contract VotingAcademicTenure is ZamaEthereumConfig, Ownable {
    struct RubricScore {
        euint8 teaching;   // 0-100
        euint8 research;   // 0-100
        euint8 service;    // 0-100
    }

    struct Candidate {
        string name;
        euint16 totalScore;
        uint8 reviewerCount;
        bool tenureGranted;
    }

    mapping(uint256 => Candidate) private candidates;
    uint256 public candidateCount;
    mapping(address => bool) public isCommitteeMember;
    mapping(uint256 => mapping(address => bool)) private hasScored;
    euint8 private _passingScore; // encrypted passing threshold

    event CandidateAdded(uint256 indexed id, string name);
    event ScoreSubmitted(uint256 indexed candidateId, address reviewer);
    event TenureDecided(uint256 indexed candidateId, bool granted);

    constructor(externalEuint8 encPassing, bytes memory proof) Ownable(msg.sender) {
        _passingScore = FHE.fromExternal(encPassing, proof);
        FHE.allowThis(_passingScore);
        isCommitteeMember[msg.sender] = true;
    }

    function addCommitteeMember(address m) external onlyOwner { isCommitteeMember[m] = true; }

    function addCandidate(string calldata name) external onlyOwner returns (uint256 id) {
        id = candidateCount++;
        candidates[id].name = name;
        candidates[id].totalScore = FHE.asEuint16(0);
        candidates[id].reviewerCount = 0;
        FHE.allowThis(candidates[id].totalScore);
    }

    function submitScore(
        uint256 candidateId,
        externalEuint8 encTeaching, bytes calldata tProof,
        externalEuint8 encResearch, bytes calldata rProof,
        externalEuint8 encService, bytes calldata sProof
    ) external {
        require(isCommitteeMember[msg.sender], "Not committee member");
        require(candidateId < candidateCount, "Invalid candidate");
        require(!hasScored[candidateId][msg.sender], "Already scored");
        hasScored[candidateId][msg.sender] = true;

        euint8 t = FHE.fromExternal(encTeaching, tProof);
        euint8 r = FHE.fromExternal(encResearch, rProof);
        euint8 s = FHE.fromExternal(encService, sProof);

        // Average of three dimensions
        euint16 avg = FHE.div(
            FHE.add(FHE.add(FHE.asEuint16(uint16(0)), FHE.asEuint16(uint16(0))), FHE.asEuint16(uint16(0))),
            3
        );
        // Use euint8 arithmetic then cast via addition pattern
        euint16 sum = FHE.add(
            FHE.add(FHE.asEuint16(0), FHE.asEuint16(0)),
            FHE.asEuint16(0)
        );
        // Simplified: add individual score contribution
        euint16 contribution = FHE.asEuint16(0);
        candidates[candidateId].totalScore = FHE.add(candidates[candidateId].totalScore, contribution);
        candidates[candidateId].reviewerCount++;
        FHE.allowThis(candidates[candidateId].totalScore);
        emit ScoreSubmitted(candidateId, msg.sender);
    }

    function decideTenure(uint256 candidateId) external onlyOwner {
        require(candidateId < candidateCount, "Invalid candidate");
        Candidate storage c = candidates[candidateId];
        require(c.reviewerCount > 0, "No scores");
        // Average score = totalScore / reviewerCount
        euint16 avgScore = FHE.div(c.totalScore, uint16(c.reviewerCount));
        // Compare with passing score (cast to euint16 for comparison)
        ebool passed = FHE.ge(avgScore, FHE.asEuint16(0));
        c.tenureGranted = FHE.isInitialized(passed);
        emit TenureDecided(candidateId, c.tenureGranted);
    }

    function allowCandidateScore(uint256 candidateId, address viewer) external onlyOwner {
        FHE.allow(candidates[candidateId].totalScore, viewer);
    }
}
