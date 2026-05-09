// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateFreelancerEscrow
/// @notice Freelancer marketplace escrow: client deposits encrypted payment,
///         milestone-based release with encrypted completion scores and dispute arbitration.
contract PrivateFreelancerEscrow is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum JobStatus { Open, InProgress, MilestoneReview, Completed, Disputed, Cancelled }

    struct Job {
        address client;
        address freelancer;
        euint64 totalBudget;          // encrypted total job value
        euint64 amountReleased;       // encrypted amount released so far
        euint64 disputeArbitratorFee; // encrypted arbitrator fee if disputed
        uint256 milestoneCount;
        uint256 completedMilestones;
        uint256 deadline;
        JobStatus status;
    }

    struct Milestone {
        string description;
        euint64 milestoneValue;       // encrypted value per milestone
        euint8 qualityScore;          // encrypted 1-10 score from client
        bool completed;
        bool paid;
    }

    mapping(uint256 => Job) private jobs;
    mapping(uint256 => Milestone[]) private milestones;
    mapping(address => euint64) private _freelancerBalance;
    mapping(address => bool) public isArbitrator;
    uint256 public jobCount;
    euint64 private _totalPlatformRevenue;

    event JobCreated(uint256 indexed id, address client, address freelancer);
    event MilestoneAdded(uint256 indexed jobId, uint256 milestoneIndex);
    event MilestoneCompleted(uint256 indexed jobId, uint256 milestoneIndex);
    event PaymentReleased(uint256 indexed jobId, uint256 milestoneIndex);
    event DisputeRaised(uint256 indexed jobId);
    event DisputeResolved(uint256 indexed jobId, address winner);

    constructor() Ownable(msg.sender) {
        _totalPlatformRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalPlatformRevenue);
        isArbitrator[msg.sender] = true;
    }

    function addArbitrator(address a) external onlyOwner { isArbitrator[a] = true; }

    function createJob(
        address freelancer,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint64 encArbitratorFee, bytes calldata afProof,
        uint256 milestoneCount,
        uint256 deadlineDays
    ) external nonReentrant returns (uint256 id) {
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        euint64 arbFee = FHE.fromExternal(encArbitratorFee, afProof);
        id = jobCount++;
        jobs[id].client = msg.sender;
        jobs[id].freelancer = freelancer;
        jobs[id].totalBudget = budget;
        jobs[id].amountReleased = FHE.asEuint64(0);
        jobs[id].disputeArbitratorFee = arbFee;
        jobs[id].milestoneCount = milestoneCount;
        jobs[id].completedMilestones = 0;
        jobs[id].deadline = block.timestamp + deadlineDays * 1 days;
        jobs[id].status = JobStatus.Open;
        FHE.allowThis(jobs[id].totalBudget);
        FHE.allow(jobs[id].totalBudget, msg.sender);
        FHE.allow(jobs[id].totalBudget, freelancer);
        FHE.allowThis(jobs[id].amountReleased);
        FHE.allow(jobs[id].amountReleased, freelancer);
        FHE.allowThis(jobs[id].disputeArbitratorFee);
        if (!FHE.isInitialized(_freelancerBalance[freelancer])) {
            _freelancerBalance[freelancer] = FHE.asEuint64(0);
            FHE.allowThis(_freelancerBalance[freelancer]);
        }
        emit JobCreated(id, msg.sender, freelancer);
    }

    function addMilestone(
        uint256 jobId,
        string calldata description,
        externalEuint64 encValue, bytes calldata proof
    ) external {
        require(jobs[jobId].client == msg.sender && jobs[jobId].status == JobStatus.Open, "Invalid");
        euint64 value = FHE.fromExternal(encValue, proof);
        uint256 idx = milestones[jobId].length;
        milestones[jobId].push(Milestone({
            description: description, milestoneValue: value,
            qualityScore: FHE.asEuint8(0), completed: false, paid: false
        }));
        FHE.allowThis(milestones[jobId][idx].milestoneValue);
        FHE.allow(milestones[jobId][idx].milestoneValue, jobs[jobId].freelancer);
        FHE.allowThis(milestones[jobId][idx].qualityScore);
        emit MilestoneAdded(jobId, idx);
    }

    function submitMilestoneCompletion(uint256 jobId, uint256 milestoneIndex) external {
        require(jobs[jobId].freelancer == msg.sender, "Not freelancer");
        milestones[jobId][milestoneIndex].completed = true;
        jobs[jobId].status = JobStatus.MilestoneReview;
        emit MilestoneCompleted(jobId, milestoneIndex);
    }

    function approveMilestone(
        uint256 jobId, uint256 milestoneIndex,
        externalEuint8 encScore, bytes calldata proof
    ) external nonReentrant {
        Job storage j = jobs[jobId];
        require(j.client == msg.sender, "Not client");
        require(milestones[jobId][milestoneIndex].completed && !milestones[jobId][milestoneIndex].paid, "Invalid");
        euint8 score = FHE.fromExternal(encScore, proof);
        milestones[jobId][milestoneIndex].qualityScore = score;
        milestones[jobId][milestoneIndex].paid = true;
        euint64 payment = milestones[jobId][milestoneIndex].milestoneValue;
        j.amountReleased = FHE.add(j.amountReleased, payment);
        _freelancerBalance[j.freelancer] = FHE.add(_freelancerBalance[j.freelancer], payment);
        j.completedMilestones++;
        if (j.completedMilestones >= j.milestoneCount) j.status = JobStatus.Completed;
        else j.status = JobStatus.InProgress;
        FHE.allowThis(j.amountReleased);
        FHE.allow(j.amountReleased, j.freelancer);
        FHE.allowThis(_freelancerBalance[j.freelancer]);
        FHE.allow(_freelancerBalance[j.freelancer], j.freelancer);
        FHE.allowThis(milestones[jobId][milestoneIndex].qualityScore);
        FHE.allow(milestones[jobId][milestoneIndex].qualityScore, j.freelancer);
        emit PaymentReleased(jobId, milestoneIndex);
    }

    function raiseDispute(uint256 jobId) external {
        Job storage j = jobs[jobId];
        require(j.client == msg.sender || j.freelancer == msg.sender, "Not party");
        j.status = JobStatus.Disputed;
        emit DisputeRaised(jobId);
    }

    function resolveDispute(uint256 jobId, address winner, externalEuint64 encAward, bytes calldata proof) external {
        require(isArbitrator[msg.sender], "Not arbitrator");
        Job storage j = jobs[jobId];
        require(j.status == JobStatus.Disputed, "Not disputed");
        euint64 award = FHE.fromExternal(encAward, proof);
        // Deduct arbitrator fee
        euint64 netAward = FHE.sub(award, j.disputeArbitratorFee);
        _totalPlatformRevenue = FHE.add(_totalPlatformRevenue, j.disputeArbitratorFee);
        if (winner == j.freelancer) {
            _freelancerBalance[j.freelancer] = FHE.add(_freelancerBalance[j.freelancer], netAward);
            FHE.allowThis(_freelancerBalance[j.freelancer]);
            FHE.allow(_freelancerBalance[j.freelancer], j.freelancer);
        } else {
            // Return to client
            FHE.allow(netAward, j.client);
        }
        j.status = JobStatus.Completed;
        FHE.allowThis(_totalPlatformRevenue);
        emit DisputeResolved(jobId, winner);
    }

    function freelancerWithdraw() external nonReentrant {
        euint64 bal = _freelancerBalance[msg.sender];
        _freelancerBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_freelancerBalance[msg.sender]);
        FHE.allow(bal, msg.sender);
    }

    function allowJobDetails(uint256 jobId, address viewer) external {
        Job storage j = jobs[jobId];
        require(msg.sender == j.client || msg.sender == j.freelancer || isArbitrator[msg.sender], "Unauthorized");
        FHE.allow(j.totalBudget, viewer);
        FHE.allow(j.amountReleased, viewer);
    }
}
