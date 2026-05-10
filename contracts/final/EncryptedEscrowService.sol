// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedEscrowService - Milestone-gated escrow with encrypted payment tranches
contract EncryptedEscrowService is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MilestoneStatus { Pending, Submitted, Approved, Disputed, Released }

    struct Milestone {
        string description;
        euint64 amount;
        MilestoneStatus status;
        uint256 deadline;
    }

    struct Escrow {
        address payer;
        address payee;
        address arbitrator;
        euint64 totalAmount;
        euint64 releasedAmount;
        uint8 milestoneCount;
        bool terminated;
    }

    mapping(uint256 => Escrow) public escrows;
    mapping(uint256 => mapping(uint8 => Milestone)) private milestones;
    uint256 public escrowCount;

    event EscrowCreated(uint256 indexed escrowId, address payer, address payee);
    event MilestoneAdded(uint256 indexed escrowId, uint8 index);
    event MilestoneSubmitted(uint256 indexed escrowId, uint8 index);
    event MilestoneApproved(uint256 indexed escrowId, uint8 index);
    event MilestoneDisputed(uint256 indexed escrowId, uint8 index);
    event ArbitratorRuled(uint256 indexed escrowId, uint8 index, bool released);

    constructor() Ownable(msg.sender) {}

    function createEscrow(
        address payee,
        address arbitrator,
        externalEuint64 encTotal,
        bytes calldata inputProof
    ) external returns (uint256 escrowId) {
        escrowId = escrowCount++;
        Escrow storage e = escrows[escrowId];
        e.payer      = msg.sender;
        e.payee      = payee;
        e.arbitrator = arbitrator;
        e.totalAmount    = FHE.fromExternal(encTotal, inputProof);
        e.releasedAmount = FHE.asEuint64(0);
        FHE.allowThis(e.totalAmount); FHE.allowThis(e.releasedAmount);
        FHE.allow(e.totalAmount, msg.sender);
        FHE.allow(e.totalAmount, payee);
        emit EscrowCreated(escrowId, msg.sender, payee);
    }

    function addMilestone(
        uint256 escrowId,
        string calldata description,
        uint256 deadlineDays,
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external {
        Escrow storage e = escrows[escrowId];
        require(e.payer == msg.sender, "Not payer");
        require(!e.terminated, "Terminated");
        uint8 idx = e.milestoneCount++;
        Milestone storage m = milestones[escrowId][idx];
        m.description = description;
        m.amount   = FHE.fromExternal(encAmount, inputProof);
        m.status   = MilestoneStatus.Pending;
        m.deadline = block.timestamp + deadlineDays * 1 days;
        FHE.allowThis(m.amount);
        FHE.allow(m.amount, e.payer); FHE.allow(m.amount, e.payee);
        emit MilestoneAdded(escrowId, idx);
    }

    function submitMilestone(uint256 escrowId, uint8 index) external {
        Escrow storage e = escrows[escrowId];
        require(e.payee == msg.sender, "Not payee");
        milestones[escrowId][index].status = MilestoneStatus.Submitted;
        emit MilestoneSubmitted(escrowId, index);
    }

    function approveMilestone(uint256 escrowId, uint8 index) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.payer == msg.sender, "Not payer");
        Milestone storage m = milestones[escrowId][index];
        require(m.status == MilestoneStatus.Submitted, "Not submitted");
        m.status = MilestoneStatus.Released;
        e.releasedAmount = FHE.add(e.releasedAmount, m.amount);
        FHE.allowThis(e.releasedAmount);
        FHE.allow(e.releasedAmount, e.payee);
        FHE.allowTransient(m.amount, e.payee);
        emit MilestoneApproved(escrowId, index);
    }

    function disputeMilestone(uint256 escrowId, uint8 index) external {
        Escrow storage e = escrows[escrowId];
        require(msg.sender == e.payer || msg.sender == e.payee, "Unauthorized");
        milestones[escrowId][index].status = MilestoneStatus.Disputed;
        emit MilestoneDisputed(escrowId, index);
    }

    function arbitratorRule(uint256 escrowId, uint8 index, bool releaseToPayee) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(msg.sender == e.arbitrator, "Not arbitrator");
        Milestone storage m = milestones[escrowId][index];
        require(m.status == MilestoneStatus.Disputed, "Not disputed");
        if (releaseToPayee) {
            m.status = MilestoneStatus.Released;
            e.releasedAmount = FHE.add(e.releasedAmount, m.amount);
            FHE.allowThis(e.releasedAmount);
            FHE.allowTransient(m.amount, e.payee);
        } else {
            m.status = MilestoneStatus.Pending;
            FHE.allowTransient(m.amount, e.payer);
        }
        emit ArbitratorRuled(escrowId, index, releaseToPayee);
    }
}
