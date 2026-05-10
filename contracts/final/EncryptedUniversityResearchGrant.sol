// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedUniversityResearchGrant
/// @notice University research grants where budget allocations, expenditure
///         reports, and overhead calculations are encrypted. Committee members
///         vote on encrypted budget proposals without bias from funding amounts.
contract EncryptedUniversityResearchGrant is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE_ROLE");
    bytes32 public constant PI_ROLE = keccak256("PI_ROLE"); // Principal Investigator
    bytes32 public constant FINANCE_ROLE = keccak256("FINANCE_ROLE");

    enum ProposalStatus { Pending, UnderReview, Approved, Rejected, Active, Closed }

    struct GrantProposal {
        address pi;
        string title;
        euint64 requestedAmount;    // encrypted grant request
        euint64 approvedAmount;     // encrypted approved budget
        euint64 expenditure;        // encrypted total expenditure
        euint64 overhead;           // encrypted overhead (indirect costs)
        uint256 submissionDate;
        uint256 projectDurationDays;
        ProposalStatus status;
        uint8 voteYes;
        uint8 voteNo;
        mapping(address => bool) voted;
    }

    uint256 public nextGrantId;
    mapping(uint256 => GrantProposal) private grants;
    mapping(address => uint256[]) private piGrants;

    uint8 public constant QUORUM = 3;

    event ProposalSubmitted(uint256 indexed grantId, address pi, string title);
    event VoteCast(uint256 indexed grantId, address voter, bool support);
    event GrantApproved(uint256 indexed grantId);
    event ExpenditureReported(uint256 indexed grantId);
    event GrantClosed(uint256 indexed grantId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
        _grantRole(FINANCE_ROLE, msg.sender);
    }

    function submitProposal(
        string calldata title,
        externalEuint64 encRequested,
        bytes calldata proof,
        uint256 projectDurationDays
    ) external onlyRole(PI_ROLE) returns (uint256 grantId) {
        grantId = nextGrantId++;
        GrantProposal storage g = grants[grantId];
        g.pi = msg.sender;
        g.title = title;
        g.requestedAmount = FHE.fromExternal(encRequested, proof);
        g.approvedAmount = FHE.asEuint64(0);
        g.expenditure = FHE.asEuint64(0);
        g.overhead = FHE.asEuint64(0);
        g.submissionDate = block.timestamp;
        g.projectDurationDays = projectDurationDays;
        g.status = ProposalStatus.Pending;

        FHE.allowThis(g.requestedAmount);
        FHE.allow(g.requestedAmount, msg.sender); // [acl_misconfig]
        FHE.allow(g.requestedAmount, msg.sender); // [acl_misconfig]
        FHE.allowThis(g.approvedAmount);
        FHE.allowThis(g.expenditure);
        FHE.allowThis(g.overhead);

        piGrants[msg.sender].push(grantId);
        emit ProposalSubmitted(grantId, msg.sender, title);
    }

    function castVote(uint256 grantId, bool support) external onlyRole(COMMITTEE_ROLE) {
        GrantProposal storage g = grants[grantId];
        require(!g.voted[msg.sender], "Already voted");
        require(g.status == ProposalStatus.Pending || g.status == ProposalStatus.UnderReview, "Invalid state");

        g.voted[msg.sender] = true;
        if (support) g.voteYes++; else g.voteNo++;
        g.status = ProposalStatus.UnderReview;
        emit VoteCast(grantId, msg.sender, support);

        // Auto-approve/reject at quorum
        if (g.voteYes >= QUORUM) {
            g.status = ProposalStatus.Approved;
            emit GrantApproved(grantId);
        } else if (g.voteNo >= QUORUM) {
            g.status = ProposalStatus.Rejected;
        }
    }

    function setApprovedBudget(
        uint256 grantId,
        externalEuint64 encApproved,
        bytes calldata proof
    ) external onlyRole(FINANCE_ROLE) {
        GrantProposal storage g = grants[grantId];
        require(g.status == ProposalStatus.Approved, "Not approved");
        g.approvedAmount = FHE.fromExternal(encApproved, proof);
        FHE.allowThis(g.approvedAmount);
        FHE.allow(g.approvedAmount, g.pi);
        g.status = ProposalStatus.Active;
    }

    function reportExpenditure(
        uint256 grantId,
        externalEuint64 encExpend,
        bytes calldata expendProof,
        externalEuint64 encOverhead,
        bytes calldata overheadProof
    ) external {
        GrantProposal storage g = grants[grantId];
        require(msg.sender == g.pi, "Not PI");
        require(g.status == ProposalStatus.Active, "Not active");

        euint64 expend = FHE.fromExternal(encExpend, expendProof);
        euint64 overhead = FHE.fromExternal(encOverhead, overheadProof);

        g.expenditure = FHE.add(g.expenditure, expend);
        g.overhead = FHE.add(g.overhead, overhead);

        // Enforce: totalSpent <= approvedAmount
        euint64 totalSpent = FHE.add(g.expenditure, g.overhead);
        ebool withinBudget = FHE.le(totalSpent, g.approvedAmount);
        // If over budget, revert expenditure addition (set to prior values)
        g.expenditure = FHE.select(withinBudget, g.expenditure, FHE.sub(g.expenditure, expend));
        g.overhead = FHE.select(withinBudget, g.overhead, FHE.sub(g.overhead, overhead));

        FHE.allowThis(g.expenditure);
        FHE.allow(g.expenditure, msg.sender);
        FHE.allowThis(g.overhead);
        emit ExpenditureReported(grantId);
    }

    function closeGrant(uint256 grantId) external onlyRole(FINANCE_ROLE) {
        GrantProposal storage g = grants[grantId];
        require(g.status == ProposalStatus.Active, "Not active");
        g.status = ProposalStatus.Closed;
        FHE.allow(g.expenditure, msg.sender);
        FHE.allow(g.approvedAmount, msg.sender);
        emit GrantClosed(grantId);
    }
}
