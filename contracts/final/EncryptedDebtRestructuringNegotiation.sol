// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedDebtRestructuringNegotiation
/// @notice Corporate debt restructuring platform where proposed haircut percentages,
///         creditor exposure sizes, and settlement offers are encrypted.
///         Prevents strategic gaming by larger creditors who might collude.
contract EncryptedDebtRestructuringNegotiation is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant DEBTOR_ROLE = keccak256("DEBTOR_ROLE");
    bytes32 public constant CREDITOR_ROLE = keccak256("CREDITOR_ROLE");
    bytes32 public constant MEDIATOR_ROLE = keccak256("MEDIATOR_ROLE");

    enum RestructuringPhase { Proposal, Voting, Accepted, Rejected, Executed }

    struct RestructuringPlan {
        address debtor;
        euint64 totalDebt;              // encrypted total outstanding debt
        euint32 proposedHaircutBps;     // encrypted haircut in basis points
        euint64 newPaymentScheduleAmt;  // encrypted new monthly payment
        uint256 proposalDate;
        uint256 votingDeadline;
        RestructuringPhase phase;
        uint8 creditorVotesFor;
        uint8 creditorVotesAgainst;
        uint8 totalCreditors;
    }

    struct CreditorClaim {
        euint64 principalExposed;       // encrypted exposure
        euint64 settledAmount;          // encrypted amount after haircut
        bool voted;
        bool support;
    }

    uint256 public nextPlanId;
    mapping(uint256 => RestructuringPlan) private plans;
    mapping(uint256 => mapping(address => CreditorClaim)) private creditorClaims;
    mapping(address => uint256[]) private debtorPlans;

    event PlanProposed(uint256 indexed planId, address debtor);
    event ClaimRegistered(uint256 indexed planId, address creditor);
    event VoteCast(uint256 indexed planId, address creditor, bool support);
    event PlanAccepted(uint256 indexed planId);
    event PlanRejected(uint256 indexed planId);
    event PlanExecuted(uint256 indexed planId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MEDIATOR_ROLE, msg.sender);
    }

    function proposePlan(
        externalEuint64 encTotalDebt,
        bytes calldata debtProof,
        externalEuint32 encHaircut,
        bytes calldata haircutProof,
        externalEuint64 encNewPayment,
        bytes calldata paymentProof,
        uint256 votingDays,
        uint8 totalCreditors
    ) external onlyRole(DEBTOR_ROLE) returns (uint256 planId) {
        planId = nextPlanId++;
        plans[planId].debtor = msg.sender;
        plans[planId].totalDebt = FHE.fromExternal(encTotalDebt, debtProof);
        plans[planId].proposedHaircutBps = FHE.fromExternal(encHaircut, haircutProof);
        plans[planId].newPaymentScheduleAmt = FHE.fromExternal(encNewPayment, paymentProof);
        plans[planId].proposalDate = block.timestamp;
        plans[planId].votingDeadline = block.timestamp + votingDays * 1 days;
        plans[planId].phase = RestructuringPhase.Proposal;
        plans[planId].creditorVotesFor = 0;
        plans[planId].creditorVotesAgainst = 0;
        plans[planId].totalCreditors = totalCreditors;

        FHE.allowThis(plans[planId].totalDebt);
        FHE.allow(plans[planId].totalDebt, msg.sender);
        FHE.allowThis(plans[planId].proposedHaircutBps);
        FHE.allowThis(plans[planId].newPaymentScheduleAmt);

        debtorPlans[msg.sender].push(planId);
        emit PlanProposed(planId, msg.sender);
    }

    function registerClaim(
        uint256 planId,
        externalEuint64 encPrincipal,
        bytes calldata proof
    ) external onlyRole(CREDITOR_ROLE) {
        RestructuringPlan storage p = plans[planId];
        require(p.phase == RestructuringPhase.Proposal, "Not in proposal phase");
        require(!creditorClaims[planId][msg.sender].voted, "Already registered");

        euint64 principal = FHE.fromExternal(encPrincipal, proof);
        creditorClaims[planId][msg.sender] = CreditorClaim({
            principalExposed: principal,
            settledAmount: FHE.asEuint64(0),
            voted: false,
            support: false
        });

        FHE.allowThis(creditorClaims[planId][msg.sender].principalExposed);
        FHE.allow(creditorClaims[planId][msg.sender].principalExposed, msg.sender);
        FHE.allowThis(creditorClaims[planId][msg.sender].settledAmount);
        emit ClaimRegistered(planId, msg.sender);
    }

    function castVote(uint256 planId, bool support) external onlyRole(CREDITOR_ROLE) {
        RestructuringPlan storage p = plans[planId];
        CreditorClaim storage c = creditorClaims[planId][msg.sender];
        require(!c.voted, "Already voted");
        require(block.timestamp <= p.votingDeadline, "Voting closed");
        require(p.phase == RestructuringPhase.Proposal, "Wrong phase");

        c.voted = true;
        c.support = support;
        if (support) p.creditorVotesFor++; else p.creditorVotesAgainst++;
        p.phase = RestructuringPhase.Voting;

        // Auto-resolve if all creditors voted
        if (p.creditorVotesFor + p.creditorVotesAgainst >= p.totalCreditors) {
            if (p.creditorVotesFor > p.creditorVotesAgainst) {
                p.phase = RestructuringPhase.Accepted;
                emit PlanAccepted(planId);
            } else {
                p.phase = RestructuringPhase.Rejected;
                emit PlanRejected(planId);
            }
        }
        emit VoteCast(planId, msg.sender, support);
    }

    function executePlan(uint256 planId) external onlyRole(MEDIATOR_ROLE) {
        RestructuringPlan storage p = plans[planId];
        require(p.phase == RestructuringPhase.Accepted, "Not accepted");
        p.phase = RestructuringPhase.Executed;
        FHE.allow(p.totalDebt, msg.sender);
        FHE.allow(p.newPaymentScheduleAmt, p.debtor);
        emit PlanExecuted(planId);
    }
}
