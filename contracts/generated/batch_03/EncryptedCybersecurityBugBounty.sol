// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedCybersecurityBugBounty
/// @notice Bug bounty platform: encrypted severity scores, encrypted bounty amounts,
///         private researcher identity, and triaged disclosure workflow.
contract EncryptedCybersecurityBugBounty is ZamaEthereumConfig, Ownable {
    enum Severity { Informational, Low, Medium, High, Critical }
    enum BugStatus { Submitted, Triaging, Accepted, Rejected, Patched, PaidOut }

    struct BugReport {
        address researcher;
        string programName;
        string encryptedVulnHash;      // IPFS hash of encrypted vuln details
        Severity severity;
        euint8  cvssScore;             // encrypted CVSS score (0-100)
        euint64 bountyAmountUSD;       // encrypted bounty award
        euint64 researcherEarnings;    // encrypted actual payout
        BugStatus status;
        uint256 submittedAt;
        uint256 patchedAt;
        bool duplicateFlag;
    }

    struct BountyProgram {
        string name;
        address sponsor;
        euint64 totalBudgetUSD;        // encrypted total budget
        euint64 spentUSD;              // encrypted amount paid
        euint64 minBountyUSD;          // encrypted minimum bounty
        euint64 maxBountyUSD;          // encrypted maximum bounty
        bool active;
    }

    mapping(uint256 => BugReport) private reports;
    mapping(uint256 => BountyProgram) private programs;
    mapping(address => bool) public isTriageTeam;
    mapping(address => bool) public isSponsor;
    mapping(address => euint64) private _researcherTotalEarnings;
    uint256 public reportCount;
    uint256 public programCount;
    euint64 private _totalBountiesPaid;
    euint64 private _platformFeeBps;

    event ProgramCreated(uint256 indexed id, string name);
    event BugSubmitted(uint256 indexed id, Severity severity);
    event BugAccepted(uint256 indexed id);
    event BugPatched(uint256 indexed id);
    event BountyPaid(uint256 indexed id, address researcher);
    event BugRejected(uint256 indexed id);

    modifier onlyTriage() {
        require(isTriageTeam[msg.sender] || msg.sender == owner(), "Not triage");
        _;
    }

    constructor(externalEuint64 encPlatformFee, bytes memory proof) Ownable(msg.sender) {
        _platformFeeBps = FHE.fromExternal(encPlatformFee, proof);
        _totalBountiesPaid = FHE.asEuint64(0);
        FHE.allowThis(_platformFeeBps);
        FHE.allowThis(_totalBountiesPaid);
        isTriageTeam[msg.sender] = true;
    }

    function addTriageTeam(address t) external onlyOwner { isTriageTeam[t] = true; }
    function addSponsor(address s) external onlyOwner { isSponsor[s] = true; }

    function createProgram(
        string calldata name,
        externalEuint64 encBudget, bytes calldata bPf,
        externalEuint64 encMin, bytes calldata minPf,
        externalEuint64 encMax, bytes calldata maxPf
    ) external returns (uint256 id) {
        require(isSponsor[msg.sender], "Not sponsor");
        euint64 budget = FHE.fromExternal(encBudget, bPf);
        euint64 minB = FHE.fromExternal(encMin, minPf);
        euint64 maxB = FHE.fromExternal(encMax, maxPf);
        id = programCount++;
        programs[id] = BountyProgram({
            name: name, sponsor: msg.sender, totalBudgetUSD: budget,
            spentUSD: FHE.asEuint64(0), minBountyUSD: minB, maxBountyUSD: maxB, active: true
        });
        FHE.allowThis(programs[id].totalBudgetUSD);
        FHE.allow(programs[id].totalBudgetUSD, msg.sender);
        FHE.allowThis(programs[id].spentUSD);
        FHE.allow(programs[id].spentUSD, msg.sender);
        FHE.allowThis(programs[id].minBountyUSD);
        FHE.allowThis(programs[id].maxBountyUSD);
        emit ProgramCreated(id, name);
    }

    function submitReport(
        uint256 programId, string calldata progName,
        string calldata vulnHash, Severity severity,
        externalEuint8 encCVSS, bytes calldata cvPf
    ) external returns (uint256 id) {
        require(programs[programId].active, "Program inactive");
        euint8 cvss = FHE.fromExternal(encCVSS, cvPf);
        id = reportCount++;
        reports[id].researcher = msg.sender;
        reports[id].programName = progName;
        reports[id].encryptedVulnHash = vulnHash;
        reports[id].severity = severity;
        reports[id].cvssScore = cvss;
        reports[id].bountyAmountUSD = FHE.asEuint64(0);
        reports[id].researcherEarnings = FHE.asEuint64(0);
        reports[id].status = BugStatus.Submitted;
        reports[id].submittedAt = block.timestamp;
        reports[id].patchedAt = 0;
        reports[id].duplicateFlag = false;
        if (!FHE.isInitialized(_researcherTotalEarnings[msg.sender])) {
            _researcherTotalEarnings[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_researcherTotalEarnings[msg.sender]);
        }
        FHE.allowThis(reports[id].cvssScore);
        FHE.allow(reports[id].cvssScore, msg.sender);
        FHE.allowThis(reports[id].bountyAmountUSD);
        FHE.allow(reports[id].bountyAmountUSD, msg.sender);
        FHE.allowThis(reports[id].researcherEarnings);
        FHE.allow(reports[id].researcherEarnings, msg.sender);
        emit BugSubmitted(id, severity);
    }

    function triageReport(uint256 reportId, bool accept) external onlyTriage {
        reports[reportId].status = accept ? BugStatus.Accepted : BugStatus.Rejected;
        if (accept) emit BugAccepted(reportId);
        else emit BugRejected(reportId);
    }

    function assignBounty(
        uint256 reportId, uint256 programId,
        externalEuint64 encBounty, bytes calldata proof
    ) external onlyTriage {
        BugReport storage r = reports[reportId];
        require(r.status == BugStatus.Accepted, "Not accepted");
        BountyProgram storage p = programs[programId];
        euint64 bounty = FHE.fromExternal(encBounty, proof);
        // Cap bounty to max
        ebool withinMax = FHE.le(bounty, p.maxBountyUSD);
        euint64 finalBounty = FHE.select(withinMax, bounty, p.maxBountyUSD);
        // Enforce min
        ebool aboveMin = FHE.ge(finalBounty, p.minBountyUSD);
        finalBounty = FHE.select(aboveMin, finalBounty, p.minBountyUSD);
        r.bountyAmountUSD = finalBounty;
        FHE.allowThis(r.bountyAmountUSD);
        FHE.allow(r.bountyAmountUSD, r.researcher);
    }

    function markPatched(uint256 reportId) external onlyTriage {
        reports[reportId].status = BugStatus.Patched;
        reports[reportId].patchedAt = block.timestamp;
        emit BugPatched(reportId);
    }

    function payBounty(uint256 reportId, uint256 programId) external onlyTriage {
        BugReport storage r = reports[reportId];
        require(r.status == BugStatus.Patched, "Not patched");
        BountyProgram storage p = programs[programId];
        euint64 platformFee = FHE.div(FHE.mul(r.bountyAmountUSD, _platformFeeBps), 10000);
        euint64 researcherNet = FHE.sub(r.bountyAmountUSD, platformFee);
        r.researcherEarnings = researcherNet;
        r.status = BugStatus.PaidOut;
        p.spentUSD = FHE.add(p.spentUSD, r.bountyAmountUSD);
        _totalBountiesPaid = FHE.add(_totalBountiesPaid, researcherNet);
        _researcherTotalEarnings[r.researcher] = FHE.add(_researcherTotalEarnings[r.researcher], researcherNet);
        FHE.allowThis(r.researcherEarnings);
        FHE.allow(r.researcherEarnings, r.researcher);
        FHE.allowThis(p.spentUSD);
        FHE.allowThis(_totalBountiesPaid);
        FHE.allowThis(_researcherTotalEarnings[r.researcher]);
        FHE.allow(_researcherTotalEarnings[r.researcher], r.researcher);
        emit BountyPaid(reportId, r.researcher);
    }

    function allowReportDetails(uint256 reportId, address viewer) external onlyTriage {
        FHE.allow(reports[reportId].cvssScore, viewer);
        FHE.allow(reports[reportId].bountyAmountUSD, viewer);
    }

    function allowPlatformStats(address viewer) external onlyOwner {
        FHE.allow(_totalBountiesPaid, viewer);
    }
}
