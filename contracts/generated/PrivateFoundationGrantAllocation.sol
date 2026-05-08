// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateFoundationGrantAllocation
/// @notice Charitable foundation grant allocation: encrypted applicant budgets,
///         confidential peer review scores, and private multi-criteria decision system.
contract PrivateFoundationGrantAllocation is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum GrantArea { SCIENCE, ARTS, EDUCATION, HEALTHCARE, ENVIRONMENT, SOCIAL_JUSTICE }
    enum ApplicationStatus { SUBMITTED, UNDER_REVIEW, AWARDED, REJECTED, WITHDRAWN }

    struct GrantApplication {
        address applicant;
        GrantArea area;
        euint64 requestedAmountUSD;      // encrypted requested grant
        euint64 awardedAmountUSD;        // encrypted final award
        euint64 compositeScoreBps;       // encrypted weighted score
        euint64 impactScoreBps;          // encrypted impact assessment
        euint64 feasibilityScoreBps;     // encrypted feasibility score
        euint64 innovationScoreBps;      // encrypted innovation score
        euint64 teamCapacityScoreBps;    // encrypted team capacity score
        uint8 reviewCount;
        ApplicationStatus status;
        uint256 submittedAt;
        bool fundingReleased;
    }

    struct ReviewerAssignment {
        address reviewer;
        uint256 applicationId;
        euint64 impactScore;
        euint64 feasibilityScore;
        euint64 innovationScore;
        euint64 teamCapacityScore;
        bool completed;
    }

    struct FoundationPool {
        euint64 totalEndowmentUSD;       // encrypted total endowment
        euint64 annualGrantBudgetUSD;    // encrypted annual budget
        euint64 allocatedThisCycleUSD;   // encrypted already allocated
        euint64 remainingBudgetUSD;      // encrypted available
        uint256 cycleStartDate;
        uint256 cycleEndDate;
        bool active;
    }

    FoundationPool private pool;
    mapping(uint256 => GrantApplication) private applications;
    mapping(bytes32 => ReviewerAssignment) private reviews; // keccak(reviewer, appId)
    mapping(address => bool) public isReviewer;
    mapping(address => bool) public isProgramOfficer;
    mapping(address => uint256) public applicantApplicationCount;

    uint256 public applicationCount;
    euint64 private _totalGrantsAwardedUSD;
    euint64 private _totalApplicantsServed;

    event ApplicationSubmitted(uint256 indexed appId, address applicant, GrantArea area);
    event ReviewAssigned(uint256 indexed appId, address reviewer);
    event ReviewSubmitted(bytes32 indexed reviewKey);
    event GrantAwarded(uint256 indexed appId, address applicant);
    event GrantRejected(uint256 indexed appId);
    event FundingReleased(uint256 indexed appId);

    constructor(
        externalEuint64 encEndowment, bytes memory endProof,
        externalEuint64 encAnnualBudget, bytes memory abProof,
        uint256 cycleStart, uint256 cycleEnd
    ) Ownable(msg.sender) {
        pool.totalEndowmentUSD = FHE.fromExternal(encEndowment, endProof);
        pool.annualGrantBudgetUSD = FHE.fromExternal(encAnnualBudget, abProof);
        pool.allocatedThisCycleUSD = FHE.asEuint64(0);
        pool.remainingBudgetUSD = pool.annualGrantBudgetUSD;
        pool.cycleStartDate = cycleStart;
        pool.cycleEndDate = cycleEnd;
        pool.active = true;
        _totalGrantsAwardedUSD = FHE.asEuint64(0);
        _totalApplicantsServed = FHE.asEuint64(0);
        FHE.allowThis(pool.totalEndowmentUSD);
        FHE.allowThis(pool.annualGrantBudgetUSD);
        FHE.allowThis(pool.allocatedThisCycleUSD);
        FHE.allowThis(pool.remainingBudgetUSD);
        FHE.allowThis(_totalGrantsAwardedUSD);
        FHE.allowThis(_totalApplicantsServed);
        isProgramOfficer[msg.sender] = true;
    }

    modifier onlyProgramOfficer() { require(isProgramOfficer[msg.sender], "Not program officer"); _; }
    modifier onlyReviewer() { require(isReviewer[msg.sender], "Not reviewer"); _; }

    function submitApplication(
        GrantArea area,
        externalEuint64 encRequestedAmount, bytes calldata raProof
    ) external nonReentrant returns (uint256 appId) {
        require(pool.active, "No active grant cycle");
        require(block.timestamp >= pool.cycleStartDate && block.timestamp <= pool.cycleEndDate, "Outside cycle");
        require(applicantApplicationCount[msg.sender] < 2, "Max 2 applications per cycle");
        euint64 requestedAmt = FHE.fromExternal(encRequestedAmount, raProof);
        // Cap at 20% of annual budget per application
        euint64 maxPerApp = FHE.div(pool.annualGrantBudgetUSD, 5);
        ebool withinCap = FHE.le(requestedAmt, maxPerApp);
        euint64 actualRequest = FHE.select(withinCap, requestedAmt, maxPerApp);
        appId = applicationCount++;
        GrantApplication storage app = applications[appId];
        app.applicant = msg.sender;
        app.area = area;
        app.requestedAmountUSD = actualRequest;
        app.awardedAmountUSD = FHE.asEuint64(0);
        app.compositeScoreBps = FHE.asEuint64(0);
        app.impactScoreBps = FHE.asEuint64(0);
        app.feasibilityScoreBps = FHE.asEuint64(0);
        app.innovationScoreBps = FHE.asEuint64(0);
        app.teamCapacityScoreBps = FHE.asEuint64(0);
        app.reviewCount = 0;
        app.status = ApplicationStatus.SUBMITTED;
        app.submittedAt = block.timestamp;
        applicantApplicationCount[msg.sender]++;
        FHE.allowThis(app.requestedAmountUSD);
        FHE.allow(app.requestedAmountUSD, msg.sender);
        FHE.allowThis(app.compositeScoreBps);
        emit ApplicationSubmitted(appId, msg.sender, area);
    }

    function submitReview(
        uint256 appId,
        externalEuint64 encImpact, bytes calldata iProof,
        externalEuint64 encFeasibility, bytes calldata fProof,
        externalEuint64 encInnovation, bytes calldata inProof,
        externalEuint64 encTeamCap, bytes calldata tcProof
    ) external onlyReviewer {
        bytes32 reviewKey = keccak256(abi.encodePacked(msg.sender, appId));
        require(!reviews[reviewKey].completed, "Already reviewed");
        GrantApplication storage app = applications[appId];
        require(app.status == ApplicationStatus.UNDER_REVIEW || app.status == ApplicationStatus.SUBMITTED, "Not reviewable");
        euint64 impact = FHE.fromExternal(encImpact, iProof);
        euint64 feasibility = FHE.fromExternal(encFeasibility, fProof);
        euint64 innovation = FHE.fromExternal(encInnovation, inProof);
        euint64 teamCap = FHE.fromExternal(encTeamCap, tcProof);
        reviews[reviewKey] = ReviewerAssignment({
            reviewer: msg.sender, applicationId: appId,
            impactScore: impact, feasibilityScore: feasibility,
            innovationScore: innovation, teamCapacityScore: teamCap,
            completed: true
        });
        // Accumulate scores (averaging approach)
        app.impactScoreBps = FHE.add(app.impactScoreBps, impact);
        app.feasibilityScoreBps = FHE.add(app.feasibilityScoreBps, feasibility);
        app.innovationScoreBps = FHE.add(app.innovationScoreBps, innovation);
        app.teamCapacityScoreBps = FHE.add(app.teamCapacityScoreBps, teamCap);
        app.reviewCount++;
        app.status = ApplicationStatus.UNDER_REVIEW;
        FHE.allowThis(app.impactScoreBps);
        FHE.allowThis(app.feasibilityScoreBps);
        FHE.allowThis(app.innovationScoreBps);
        FHE.allowThis(app.teamCapacityScoreBps);
        FHE.allowThis(reviews[reviewKey].impactScore);
        FHE.allowThis(reviews[reviewKey].feasibilityScore);
        emit ReviewSubmitted(reviewKey);
    }

    function makeAwardDecision(
        uint256 appId,
        bool award,
        externalEuint64 encAwardAmount, bytes calldata aaProof
    ) external onlyProgramOfficer {
        GrantApplication storage app = applications[appId];
        require(app.status == ApplicationStatus.UNDER_REVIEW && app.reviewCount >= 2, "Not ready for decision");
        // Compute average scores
        if (app.reviewCount > 0) {
            app.impactScoreBps = FHE.div(app.impactScoreBps, FHE.asEuint64(app.reviewCount));
            app.feasibilityScoreBps = FHE.div(app.feasibilityScoreBps, FHE.asEuint64(app.reviewCount));
            app.innovationScoreBps = FHE.div(app.innovationScoreBps, FHE.asEuint64(app.reviewCount));
            app.teamCapacityScoreBps = FHE.div(app.teamCapacityScoreBps, FHE.asEuint64(app.reviewCount));
            // Weighted composite: 40% impact, 25% feasibility, 20% innovation, 15% team
            app.compositeScoreBps = FHE.add(
                FHE.add(FHE.div(FHE.mul(app.impactScoreBps, 4000), 10000),
                         FHE.div(FHE.mul(app.feasibilityScoreBps, 2500), 10000)),
                FHE.add(FHE.div(FHE.mul(app.innovationScoreBps, 2000), 10000),
                         FHE.div(FHE.mul(app.teamCapacityScoreBps, 1500), 10000)));
            FHE.allowThis(app.compositeScoreBps);
            FHE.allow(app.compositeScoreBps, app.applicant);
        }
        if (award) {
            euint64 awardAmt = FHE.fromExternal(encAwardAmount, aaProof);
            ebool withinBudget = FHE.le(awardAmt, pool.remainingBudgetUSD);
            euint64 actualAward = FHE.select(withinBudget, awardAmt, pool.remainingBudgetUSD);
            app.awardedAmountUSD = actualAward;
            app.status = ApplicationStatus.AWARDED;
            pool.allocatedThisCycleUSD = FHE.add(pool.allocatedThisCycleUSD, actualAward);
            pool.remainingBudgetUSD = FHE.sub(pool.remainingBudgetUSD, actualAward);
            _totalGrantsAwardedUSD = FHE.add(_totalGrantsAwardedUSD, actualAward);
            _totalApplicantsServed = FHE.add(_totalApplicantsServed, FHE.asEuint64(1));
            FHE.allowThis(app.awardedAmountUSD);
            FHE.allow(app.awardedAmountUSD, app.applicant);
            FHE.allowThis(pool.allocatedThisCycleUSD);
            FHE.allowThis(pool.remainingBudgetUSD);
            FHE.allowThis(_totalGrantsAwardedUSD);
            FHE.allowThis(_totalApplicantsServed);
            emit GrantAwarded(appId, app.applicant);
        } else {
            app.status = ApplicationStatus.REJECTED;
            emit GrantRejected(appId);
        }
    }

    function releaseFunding(uint256 appId) external onlyProgramOfficer {
        GrantApplication storage app = applications[appId];
        require(app.status == ApplicationStatus.AWARDED && !app.fundingReleased, "Cannot release");
        app.fundingReleased = true;
        FHE.allowTransient(app.awardedAmountUSD, app.applicant);
        emit FundingReleased(appId);
    }

    function addReviewer(address r) external onlyOwner { isReviewer[r] = true; }
    function addProgramOfficer(address po) external onlyOwner { isProgramOfficer[po] = true; }
    function allowFoundationStats(address donor) external onlyOwner {
        FHE.allow(_totalGrantsAwardedUSD, donor);
        FHE.allow(_totalApplicantsServed, donor);
        FHE.allow(pool.remainingBudgetUSD, donor);
    }
}
