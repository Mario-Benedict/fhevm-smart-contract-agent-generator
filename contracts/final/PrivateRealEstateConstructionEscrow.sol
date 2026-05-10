// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateRealEstateConstructionEscrow
/// @notice Encrypted construction project escrow: hidden contractor draws, confidential
///         inspection completion percentages, private lien waiver tracking, and encrypted
///         retainage release schedules tied to milestone completion.
contract PrivateRealEstateConstructionEscrow is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MilestoneStatus { Pending, InProgress, InspectionRequired, Approved, Rejected }

    struct ConstructionProject {
        address developer;
        address generalContractor;
        address lender;
        string projectRef;
        euint64 totalBudgetUSD;        // encrypted total budget
        euint64 disbursedUSD;          // encrypted total disbursed
        euint64 retainageHeldUSD;      // encrypted retainage held
        euint64 approvedContingencyUSD;// encrypted contingency budget
        euint16 completionBps;         // encrypted overall completion %
        uint256 startDate;
        uint256 expectedCompletionDate;
    }

    struct PaymentMilestone {
        uint256 projectId;
        string milestoneDescription;
        euint64 drawAmountUSD;         // encrypted draw request
        euint64 retainageBps;          // encrypted retainage % held
        euint16 completionPctBps;      // encrypted milestone completion %
        MilestoneStatus status;
        uint256 submittedAt;
    }

    mapping(uint256 => ConstructionProject) private projects;
    mapping(uint256 => PaymentMilestone) private milestones;
    mapping(address => bool) public isConstructionInspector;

    uint256 public projectCount;
    uint256 public milestoneCount;
    euint64 private _totalEscrowedUSD;
    euint64 private _totalDisbursedUSD;

    event ProjectCreated(uint256 indexed id, string projectRef);
    event MilestoneSubmitted(uint256 indexed milestoneId, uint256 projectId);
    event MilestoneApproved(uint256 indexed milestoneId, uint256 approvedAt);

    modifier onlyInspector() {
        require(isConstructionInspector[msg.sender] || msg.sender == owner(), "Not inspector");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalEscrowedUSD = FHE.asEuint64(0);
        _totalDisbursedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalEscrowedUSD);
        FHE.allowThis(_totalDisbursedUSD);
        isConstructionInspector[msg.sender] = true;
    }

    function addInspector(address i) external onlyOwner { isConstructionInspector[i] = true; }

    function createProject(
        address developer, address generalContractor, address lender, string calldata projectRef,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint64 encContingency, bytes calldata conProof,
        uint256 durationDays
    ) external onlyOwner returns (uint256 id) {
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        euint64 contingency = FHE.fromExternal(encContingency, conProof);
        id = projectCount++;
        projects[id].developer = developer;
        projects[id].generalContractor = generalContractor;
        projects[id].lender = lender;
        projects[id].projectRef = projectRef;
        projects[id].totalBudgetUSD = budget;
        projects[id].disbursedUSD = FHE.asEuint64(0);
        projects[id].retainageHeldUSD = FHE.asEuint64(0);
        projects[id].approvedContingencyUSD = contingency;
        projects[id].completionBps = FHE.asEuint16(0);
        projects[id].startDate = block.timestamp;
        projects[id].expectedCompletionDate = block.timestamp + durationDays * 1 days;
        _totalEscrowedUSD = FHE.add(_totalEscrowedUSD, budget);
        FHE.allowThis(projects[id].totalBudgetUSD); FHE.allow(projects[id].totalBudgetUSD, developer); FHE.allow(projects[id].totalBudgetUSD, lender);
        FHE.allowThis(projects[id].disbursedUSD); FHE.allow(projects[id].disbursedUSD, developer);
        FHE.allowThis(projects[id].retainageHeldUSD); FHE.allow(projects[id].retainageHeldUSD, developer);
        FHE.allowThis(projects[id].approvedContingencyUSD); FHE.allow(projects[id].approvedContingencyUSD, developer);
        FHE.allowThis(projects[id].completionBps); FHE.allow(projects[id].completionBps, developer);
        FHE.allowThis(_totalEscrowedUSD);
        emit ProjectCreated(id, projectRef);
    }

    function submitMilestoneDraw(
        uint256 projectId, string calldata milestoneDesc,
        externalEuint64 encDrawAmt, bytes calldata daProof,
        externalEuint64 encRetainageBps, bytes calldata rbProof,
        externalEuint16 encCompletion, bytes calldata compProof
    ) external nonReentrant returns (uint256 msId) {
        ConstructionProject storage p = projects[projectId];
        require(msg.sender == p.generalContractor, "Not GC");
        euint64 drawAmt = FHE.fromExternal(encDrawAmt, daProof);
        euint64 retainageBps = FHE.fromExternal(encRetainageBps, rbProof);
        euint16 completionPct = FHE.fromExternal(encCompletion, compProof);
        msId = milestoneCount++;
        milestones[msId] = PaymentMilestone({
            projectId: projectId, milestoneDescription: milestoneDesc, drawAmountUSD: drawAmt,
            retainageBps: retainageBps, completionPctBps: completionPct,
            status: MilestoneStatus.InspectionRequired, submittedAt: block.timestamp
        });
        FHE.allowThis(milestones[msId].drawAmountUSD); FHE.allow(milestones[msId].drawAmountUSD, msg.sender); FHE.allow(milestones[msId].drawAmountUSD, p.developer); FHE.allow(milestones[msId].drawAmountUSD, p.lender);
        FHE.allowThis(milestones[msId].retainageBps);
        FHE.allowThis(milestones[msId].completionPctBps); FHE.allow(milestones[msId].completionPctBps, p.developer);
        emit MilestoneSubmitted(msId, projectId);
    }

    function approveMilestone(uint256 milestoneId) external onlyInspector nonReentrant {
        PaymentMilestone storage ms = milestones[milestoneId];
        require(ms.status == MilestoneStatus.InspectionRequired, "Not pending");
        ms.status = MilestoneStatus.Approved;
        ConstructionProject storage p = projects[ms.projectId];
        // Retainage = drawAmt * retainageBps / 10000 (plaintext divisor)
        euint64 retainage = FHE.div(ms.drawAmountUSD, 10); // 10% fixed retainage (plaintext)
        euint64 netDisbursement = FHE.sub(ms.drawAmountUSD, retainage);
        p.disbursedUSD = FHE.add(p.disbursedUSD, netDisbursement);
        p.retainageHeldUSD = FHE.add(p.retainageHeldUSD, retainage);
        p.completionBps = ms.completionPctBps;
        _totalDisbursedUSD = FHE.add(_totalDisbursedUSD, netDisbursement);
        FHE.allowThis(p.disbursedUSD); FHE.allow(p.disbursedUSD, p.developer);
        FHE.allowThis(p.retainageHeldUSD); FHE.allow(p.retainageHeldUSD, p.developer);
        FHE.allowThis(p.completionBps); FHE.allow(p.completionBps, p.developer);
        FHE.allowThis(_totalDisbursedUSD);
        emit MilestoneApproved(milestoneId, block.timestamp);
    }

    function allowEscrowView(address viewer) external onlyOwner {
        FHE.allow(_totalEscrowedUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalEscrowedUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalDisbursedUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalDisbursedUSD, viewer);
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