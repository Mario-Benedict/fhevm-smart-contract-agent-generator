// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialBountyBoard - Encrypted bug-bounty program with private severity-based payouts
contract ConfidentialBountyBoard is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Severity { Informational, Low, Medium, High, Critical }

    struct BountyProgram {
        string  programName;
        euint64[5] rewardByLevel; // index 0=Info … 4=Critical
        euint64 totalBudget;
        euint64 disbursed;
        bool    active;
    }

    struct BugReport {
        uint256 programId;
        address reporter;
        string  reportHash;   // IPFS CID
        Severity severity;
        euint64 rewardAmount;
        bool    validated;
        bool    paid;
        uint256 submittedAt;
    }

    mapping(uint256 => BountyProgram) public programs;
    mapping(uint256 => BugReport)     public reports;
    mapping(address => euint64)       public reporterEarnings;
    uint256 public programCount;
    uint256 public reportCount;

    event ProgramCreated(uint256 indexed programId, string name);
    event ReportSubmitted(uint256 indexed reportId, uint256 indexed programId);
    event ReportValidated(uint256 indexed reportId, Severity severity);
    event RewardPaid(uint256 indexed reportId, address indexed reporter);

    constructor() Ownable(msg.sender) {}

    function createProgram(
        string calldata name,
        externalEuint64[5] calldata encRewards,
        bytes[5] calldata proofs,
        externalEuint64 calldata encBudget, bytes calldata budgetProof
    ) external onlyOwner returns (uint256 programId) {
        programId = programCount++;
        BountyProgram storage p = programs[programId];
        p.programName = name;
        p.totalBudget = FHE.fromExternal(encBudget, budgetProof);
        p.disbursed   = FHE.asEuint64(0);
        p.active      = true;
        FHE.allowThis(p.totalBudget); FHE.allowThis(p.disbursed);
        for (uint8 i = 0; i < 5; i++) {
            p.rewardByLevel[i] = FHE.fromExternal(encRewards[i], proofs[i]);
            FHE.allowThis(p.rewardByLevel[i]);
        }
        emit ProgramCreated(programId, name);
    }

    function submitReport(
        uint256 programId,
        string calldata reportHash
    ) external returns (uint256 reportId) {
        require(programs[programId].active, "Program inactive");
        reportId = reportCount++;
        BugReport storage r = reports[reportId];
        r.programId   = programId;
        r.reporter    = msg.sender;
        r.reportHash  = reportHash;
        r.severity    = Severity.Informational;
        r.rewardAmount = FHE.asEuint64(0);
        r.submittedAt = block.timestamp;
        FHE.allowThis(r.rewardAmount);
        if (reporterEarnings[msg.sender].unwrap() == 0) {
            reporterEarnings[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(reporterEarnings[msg.sender]);
        }
        emit ReportSubmitted(reportId, programId);
    }

    function validateReport(uint256 reportId, Severity severity) external onlyOwner {
        BugReport storage r = reports[reportId];
        require(!r.validated, "Already validated");
        r.severity  = severity;
        r.validated = true;
        BountyProgram storage p = programs[r.programId];
        r.rewardAmount = p.rewardByLevel[uint8(severity)];
        FHE.allowThis(r.rewardAmount);
        FHE.allow(r.rewardAmount, r.reporter);
        emit ReportValidated(reportId, severity);
    }

    function payReward(uint256 reportId) external onlyOwner nonReentrant {
        BugReport storage r = reports[reportId];
        require(r.validated && !r.paid, "Invalid state");
        r.paid = true;
        BountyProgram storage p = programs[r.programId];
        p.disbursed = FHE.add(p.disbursed, r.rewardAmount);
        reporterEarnings[r.reporter] = FHE.add(reporterEarnings[r.reporter], r.rewardAmount);
        FHE.allowThis(p.disbursed); FHE.allowThis(reporterEarnings[r.reporter]);
        FHE.allow(reporterEarnings[r.reporter], r.reporter);
        FHE.allowTransient(r.rewardAmount, r.reporter);
        emit RewardPaid(reportId, r.reporter);
    }
}
