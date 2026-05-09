// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CybersecurityPrivateBugBounty
/// @notice Bug bounty program where vulnerability severity scores and bounty
///         payouts are encrypted. Researchers cannot see competing bounty sizes
///         or existing CVE severity scores before submission.
contract CybersecurityPrivateBugBounty is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum VulnerabilityStatus { Submitted, Triaging, Confirmed, Disputed, Rewarded, Duplicate }

    struct BugReport {
        address researcher;
        string cvssHash;          // hash of CVSS vector (public)
        euint8 severityScore;     // encrypted: 1=info, 2=low, 3=med, 4=high, 5=critical
        euint64 bountyAmount;     // encrypted reward
        VulnerabilityStatus status;
        uint256 submittedAt;
        uint256 resolvedAt;
        bool duplicate;
    }

    struct BountyProgram {
        string programName;
        euint64 maxBounty;        // encrypted maximum payout
        euint64 totalPool;        // encrypted pool
        euint64 disbursed;
        euint8 minSeverityToReward; // encrypted minimum severity for payout
        bool active;
    }

    mapping(uint256 => BountyProgram) private programs;
    uint256 public programCount;
    mapping(uint256 => BugReport[]) private reports;  // programId => reports
    mapping(address => euint64) private researcherBalance;
    mapping(address => bool) public isTriager;
    euint64 private _platformCutBps;

    event ProgramCreated(uint256 indexed id, string name);
    event ReportSubmitted(uint256 indexed programId, uint256 reportIndex, address researcher);
    event BountyPaid(uint256 indexed programId, uint256 reportIndex, address researcher);

    constructor(externalEuint64 encPlatformCut, bytes memory proof) Ownable(msg.sender) {
        _platformCutBps = FHE.fromExternal(encPlatformCut, proof);
        FHE.allowThis(_platformCutBps);
    }

    function addTriager(address t) external onlyOwner { isTriager[t] = true; }

    function createProgram(
        string calldata name,
        externalEuint64 encMaxBounty, bytes calldata mProof,
        externalEuint64 encPool, bytes calldata pProof,
        externalEuint8 encMinSeverity, bytes calldata sProof
    ) external onlyOwner returns (uint256 id) {
        id = programCount++;
        programs[id].programName = name;
        programs[id].maxBounty = FHE.fromExternal(encMaxBounty, mProof);
        programs[id].totalPool = FHE.fromExternal(encPool, pProof);
        programs[id].minSeverityToReward = FHE.fromExternal(encMinSeverity, sProof);
        programs[id].disbursed = FHE.asEuint64(0);
        programs[id].active = true;
        FHE.allowThis(programs[id].maxBounty);
        FHE.allowThis(programs[id].totalPool);
        FHE.allowThis(programs[id].minSeverityToReward);
        FHE.allowThis(programs[id].disbursed);
        emit ProgramCreated(id, name);
    }

    function submitReport(
        uint256 programId, string calldata cvssHash,
        externalEuint8 encSeverity, bytes calldata sProof
    ) external nonReentrant returns (uint256 idx) {
        BountyProgram storage prog = programs[programId];
        require(prog.active, "Program closed");
        idx = reports[programId].length;
        reports[programId].push(BugReport({
            researcher: msg.sender, cvssHash: cvssHash,
            severityScore: FHE.fromExternal(encSeverity, sProof),
            bountyAmount: FHE.asEuint64(0),
            status: VulnerabilityStatus.Submitted,
            submittedAt: block.timestamp, resolvedAt: 0, duplicate: false
        }));
        FHE.allowThis(reports[programId][idx].severityScore);
        FHE.allowThis(reports[programId][idx].bountyAmount);
        emit ReportSubmitted(programId, idx, msg.sender);
    }

    function triageReport(
        uint256 programId, uint256 reportIdx,
        bool confirmed,
        externalEuint64 encBounty, bytes calldata proof
    ) external {
        require(isTriager[msg.sender], "Not triager");
        BugReport storage r = reports[programId][reportIdx];
        require(r.status == VulnerabilityStatus.Submitted || r.status == VulnerabilityStatus.Triaging, "Wrong status");
        if (confirmed) {
            r.status = VulnerabilityStatus.Confirmed;
            euint64 proposedBounty = FHE.fromExternal(encBounty, proof);
            BountyProgram storage prog = programs[programId];
            // Bounty = min(proposed, maxBounty)
            ebool withinMax = FHE.le(proposedBounty, prog.maxBounty);
            euint64 actualBounty = FHE.select(withinMax, proposedBounty, prog.maxBounty);
            // Check severity meets minimum
            ebool sevOk = FHE.ge(r.severityScore, prog.minSeverityToReward);
            euint64 finalBounty = FHE.select(sevOk, actualBounty, FHE.asEuint64(0));
            r.bountyAmount = finalBounty;
            FHE.allowThis(r.bountyAmount);
            FHE.allow(r.bountyAmount, r.researcher);
        } else {
            r.status = VulnerabilityStatus.Disputed;
        }
    }

    function payBounty(uint256 programId, uint256 reportIdx) external onlyOwner nonReentrant {
        BugReport storage r = reports[programId][reportIdx];
        require(r.status == VulnerabilityStatus.Confirmed && !r.duplicate, "Not payable");
        r.status = VulnerabilityStatus.Rewarded;
        r.resolvedAt = block.timestamp;
        BountyProgram storage prog = programs[programId];
        euint64 fee = FHE.div(FHE.mul(r.bountyAmount, _platformCutBps), 10000);
        euint64 net = FHE.sub(r.bountyAmount, fee);
        researcherBalance[r.researcher] = FHE.add(researcherBalance[r.researcher], net);
        prog.disbursed = FHE.add(prog.disbursed, r.bountyAmount);
        prog.totalPool = FHE.sub(prog.totalPool, r.bountyAmount);
        FHE.allowThis(researcherBalance[r.researcher]);
        FHE.allow(researcherBalance[r.researcher], r.researcher);
        FHE.allow(fee, owner());
        FHE.allowThis(prog.disbursed);
        FHE.allowThis(prog.totalPool);
        emit BountyPaid(programId, reportIdx, r.researcher);
    }

    function withdrawBalance() external nonReentrant {
        euint64 balance = researcherBalance[msg.sender];
        researcherBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allow(balance, msg.sender);
        FHE.allowThis(researcherBalance[msg.sender]);
    }

    function allowProgramData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(programs[id].totalPool, viewer);
        FHE.allow(programs[id].maxBounty, viewer);
    }
}
