// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateGigEconomyEscrow - Encrypted freelance payments with private ratings and dispute resolution
contract PrivateGigEconomyEscrow is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Project {
        address client;
        address freelancer;
        euint64 totalBudget;
        euint64 paidAmount;
        euint64 platformFeeBps;
        uint8   milestoneCount;
        bool    completed;
        bool    disputed;
        uint256 createdAt;
        uint256 deadline;
    }

    struct Milestone {
        string  description;
        euint64 amount;
        bool    approved;
        bool    paid;
        uint256 dueDate;
    }

    struct Review {
        euint8  qualityScore;     // 1-5
        euint8  communicationScore;
        euint8  timelinessScore;
        bool    submitted;
    }

    mapping(uint256 => Project)   public projects;
    mapping(uint256 => mapping(uint8 => Milestone)) private milestones;
    mapping(uint256 => Review)    private clientReviews;   // client rates freelancer
    mapping(uint256 => Review)    private freelancerReviews; // freelancer rates client
    mapping(address => euint64)   public reputationScore;
    mapping(address => bool)      private _reputationInitialized;
    mapping(address => uint32)    public completedProjects;
    uint256 public projectCount;

    event ProjectCreated(uint256 indexed projectId, address client, address freelancer);
    event MilestoneApproved(uint256 indexed projectId, uint8 milestoneIdx);
    event MilestonePaid(uint256 indexed projectId, uint8 milestoneIdx);
    event ProjectDisputed(uint256 indexed projectId);
    event ReviewSubmitted(uint256 indexed projectId, bool isClientReview);

    constructor() Ownable(msg.sender) {}

    function createProject(
        address freelancer,
        uint256 deadlineDays,
        externalEuint64 encBudget, bytes calldata budgetProof,
        externalEuint64 encFee,    bytes calldata feeProof
    ) external returns (uint256 projectId) {
        projectId = projectCount++;
        Project storage p = projects[projectId];
        p.client        = msg.sender;
        p.freelancer    = freelancer;
        p.totalBudget   = FHE.fromExternal(encBudget, budgetProof);
        p.platformFeeBps = FHE.fromExternal(encFee,   feeProof);
        p.paidAmount    = FHE.asEuint64(0);
        p.createdAt     = block.timestamp;
        p.deadline      = block.timestamp + deadlineDays * 1 days;
        FHE.allowThis(p.totalBudget); FHE.allowThis(p.platformFeeBps); FHE.allowThis(p.paidAmount);
        FHE.allow(p.totalBudget, msg.sender); FHE.allow(p.totalBudget, freelancer);
        if (!_reputationInitialized[freelancer]) {
            reputationScore[freelancer] = FHE.asEuint64(50);
            FHE.allowThis(reputationScore[freelancer]);
            _reputationInitialized[freelancer] = true;
        }
        emit ProjectCreated(projectId, msg.sender, freelancer);
    }

    function addMilestone(
        uint256 projectId,
        string calldata description,
        uint256 dueDays,
        externalEuint64 encAmount, bytes calldata inputProof
    ) external {
        Project storage p = projects[projectId];
        require(p.client == msg.sender, "Not client");
        uint8 idx = p.milestoneCount++;
        Milestone storage m = milestones[projectId][idx];
        m.description = description;
        m.amount      = FHE.fromExternal(encAmount, inputProof);
        m.dueDate     = block.timestamp + dueDays * 1 days;
        FHE.allowThis(m.amount);
        FHE.allow(m.amount, p.client); FHE.allow(m.amount, p.freelancer);
    }

    function approveMilestone(uint256 projectId, uint8 milestoneIdx) external {
        Project storage p = projects[projectId];
        require(p.client == msg.sender, "Not client");
        milestones[projectId][milestoneIdx].approved = true;
        emit MilestoneApproved(projectId, milestoneIdx);
    }

    function payMilestone(uint256 projectId, uint8 milestoneIdx) external nonReentrant {
        Project storage p = projects[projectId];
        require(p.client == msg.sender, "Not client");
        Milestone storage m = milestones[projectId][milestoneIdx];
        require(m.approved && !m.paid, "Not approved or already paid");
        m.paid = true;
        euint64 fee = FHE.div(FHE.mul(m.amount, p.platformFeeBps), 10000);
        euint64 net = FHE.sub(m.amount, fee);
        p.paidAmount = FHE.add(p.paidAmount, m.amount);
        FHE.allowThis(p.paidAmount);
        FHE.allowTransient(net, p.freelancer);
        emit MilestonePaid(projectId, milestoneIdx);
    }

    function submitReview(
        uint256 projectId, bool isClientReview,
        externalEuint8 encQuality, bytes calldata qualityProof,
        externalEuint8 encComm,    bytes calldata commProof,
        externalEuint8 encTime,    bytes calldata timeProof
    ) external {
        Project storage p = projects[projectId];
        if (isClientReview) {
            require(p.client == msg.sender, "Not client");
            Review storage r = clientReviews[projectId];
            require(!r.submitted, "Already reviewed");
            r.qualityScore       = FHE.fromExternal(encQuality, qualityProof);
            r.communicationScore = FHE.fromExternal(encComm,    commProof);
            r.timelinessScore    = FHE.fromExternal(encTime,    timeProof);
            r.submitted          = true;
            FHE.allowThis(r.qualityScore); FHE.allowThis(r.communicationScore); FHE.allowThis(r.timelinessScore);
            FHE.allow(r.qualityScore, p.freelancer);
            // update freelancer rep
            reputationScore[p.freelancer] = FHE.div(FHE.add(reputationScore[p.freelancer], r.qualityScore), 2);
            FHE.allowThis(reputationScore[p.freelancer]);
            FHE.allow(reputationScore[p.freelancer], p.freelancer);
            completedProjects[p.freelancer]++;
        } else {
            require(p.freelancer == msg.sender, "Not freelancer");
            Review storage r = freelancerReviews[projectId];
            require(!r.submitted, "Already reviewed");
            r.qualityScore       = FHE.fromExternal(encQuality, qualityProof);
            r.communicationScore = FHE.fromExternal(encComm,    commProof);
            r.timelinessScore    = FHE.fromExternal(encTime,    timeProof);
            r.submitted          = true;
            FHE.allowThis(r.qualityScore);
            FHE.allow(r.qualityScore, p.client);
        }
        emit ReviewSubmitted(projectId, isClientReview);
    }

    function raiseDispute(uint256 projectId) external {
        Project storage p = projects[projectId];
        require(msg.sender == p.client || msg.sender == p.freelancer, "Not party");
        p.disputed = true;
        emit ProjectDisputed(projectId);
    }
}
