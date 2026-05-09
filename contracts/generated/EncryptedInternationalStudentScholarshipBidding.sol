// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedInternationalStudentScholarshipBidding
/// @notice Competitive scholarship bidding for international universities with
///         encrypted financial need assessments, academic merit scores,
///         nationality-based award quotas, and confidential committee rankings.
contract EncryptedInternationalStudentScholarshipBidding is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum ScholarshipType { MERIT, NEED_BASED, ATHLETIC, RESEARCH, DIVERSITY, CORPORATE_SPONSORED }
    enum ApplicationStatus { SUBMITTED, UNDER_REVIEW, SHORTLISTED, AWARDED, WAITLISTED, REJECTED }
    enum AcademicLevel { UNDERGRADUATE, MASTERS, PHD, POSTDOCTORAL, PROFESSIONAL }

    struct ScholarshipPool {
        ScholarshipType scholarshipType;
        AcademicLevel level;
        euint64 totalFundingUSD;          // encrypted total scholarship pool
        euint64 remainingFundingUSD;      // encrypted remaining budget
        euint64 perAwardMinimumUSD;       // encrypted minimum individual award
        euint64 perAwardMaximumUSD;       // encrypted maximum individual award
        euint32 maxRecipients;            // encrypted max number of recipients
        euint32 awardedCount;             // encrypted current awarded count
        euint32 nationalityQuotaSlots;    // encrypted slots per nationality
        uint256 applicationDeadline;
        uint256 awardDate;
        bool active;
    }

    struct Application {
        bytes32 poolId;
        address applicant;
        ApplicationStatus status;
        euint64 requestedAmountUSD;       // encrypted requested scholarship amount
        euint64 awardedAmountUSD;         // encrypted final awarded amount
        euint64 financialNeedScore;       // encrypted financial need (0-100)
        euint64 academicMeritScore;       // encrypted GPA/test composite (0-100)
        euint64 researchScore;            // encrypted research/publication score
        euint64 committeeRankScore;       // encrypted committee composite rank
        euint64 nationalityQuotaUsed;     // encrypted nationality quota consumed
        euint32 countryCode;              // encrypted ISO country code
        uint256 submittedAt;
        bool financialVerified;
        bool academicVerified;
    }

    struct CommitteeScore {
        address reviewer;
        euint64 score;                    // encrypted individual reviewer score
        euint64 financialWeight;          // encrypted financial need weight
        euint64 meritWeight;              // encrypted merit weight
        bool submitted;
    }

    mapping(bytes32 => ScholarshipPool) private pools;
    mapping(bytes32 => Application) private applications;
    mapping(bytes32 => CommitteeScore[]) private committeeScores;
    mapping(bytes32 => euint32) private nationalityQuotaUsed; // poolId+countryCode => used slots
    mapping(address => bool) public authorizedCommitteeMember;

    euint64 private _totalScholarshipsAwarded;   // encrypted total awarded
    euint64 private _totalApplicantsServed;      // encrypted total recipients
    euint64 private _needBasedFundingDeployed;   // encrypted need-based total

    event PoolCreated(bytes32 indexed poolId, ScholarshipType scholarshipType);
    event ApplicationSubmitted(bytes32 indexed applicationId, bytes32 indexed poolId);
    event ApplicationShortlisted(bytes32 indexed applicationId);
    event ScholarshipAwarded(bytes32 indexed applicationId, bytes32 indexed poolId);
    event CommitteeScoreSubmitted(bytes32 indexed applicationId, address reviewer);

    constructor() Ownable(msg.sender) {
        _totalScholarshipsAwarded = FHE.asEuint64(0);
        _totalApplicantsServed = FHE.asEuint64(0);
        _needBasedFundingDeployed = FHE.asEuint64(0);
        FHE.allowThis(_totalScholarshipsAwarded);
        FHE.allowThis(_totalApplicantsServed);
        FHE.allowThis(_needBasedFundingDeployed);
        authorizedCommitteeMember[msg.sender] = true;
    }

    function createPool(
        ScholarshipType scholarshipType,
        AcademicLevel level,
        externalEuint64 encTotalFunding, bytes calldata tfProof,
        externalEuint64 encMinAward, bytes calldata minProof,
        externalEuint64 encMaxAward, bytes calldata maxProof,
        externalEuint32 encMaxRecipients, bytes calldata mrProof,
        externalEuint32 encNatQuota, bytes calldata nqProof,
        uint256 applicationDeadline,
        uint256 awardDate
    ) external onlyOwner returns (bytes32 poolId) {
        euint64 totalFunding = FHE.fromExternal(encTotalFunding, tfProof);
        euint64 minAward = FHE.fromExternal(encMinAward, minProof);
        euint64 maxAward = FHE.fromExternal(encMaxAward, maxProof);
        euint32 maxRecipients = FHE.fromExternal(encMaxRecipients, mrProof);
        euint32 natQuota = FHE.fromExternal(encNatQuota, nqProof);

        poolId = keccak256(abi.encodePacked(scholarshipType, level, applicationDeadline, block.timestamp));

        pools[poolId] = ScholarshipPool({
            scholarshipType: scholarshipType,
            level: level,
            totalFundingUSD: totalFunding,
            remainingFundingUSD: totalFunding,
            perAwardMinimumUSD: minAward,
            perAwardMaximumUSD: maxAward,
            maxRecipients: maxRecipients,
            awardedCount: FHE.asEuint32(0),
            nationalityQuotaSlots: natQuota,
            applicationDeadline: applicationDeadline,
            awardDate: awardDate,
            active: true
        });

        FHE.allowThis(totalFunding); FHE.allowThis(minAward); FHE.allowThis(maxAward);
        FHE.allowThis(maxRecipients); FHE.allowThis(natQuota);
        FHE.allowThis(pools[poolId].awardedCount);
        emit PoolCreated(poolId, scholarshipType);
    }

    function submitApplication(
        bytes32 poolId,
        externalEuint64 encRequestedAmount, bytes calldata raProof,
        externalEuint64 encFinancialNeed, bytes calldata fnProof,
        externalEuint64 encAcademicMerit, bytes calldata amProof,
        externalEuint64 encResearchScore, bytes calldata rsProof,
        externalEuint32 encCountryCode, bytes calldata ccProof
    ) external nonReentrant returns (bytes32 applicationId) {
        ScholarshipPool storage pool = pools[poolId];
        require(pool.active, "Pool not active");
        require(block.timestamp <= pool.applicationDeadline, "Deadline passed");

        euint64 requestedAmount = FHE.fromExternal(encRequestedAmount, raProof);
        euint64 financialNeed = FHE.fromExternal(encFinancialNeed, fnProof);
        euint64 academicMerit = FHE.fromExternal(encAcademicMerit, amProof);
        euint64 researchScore = FHE.fromExternal(encResearchScore, rsProof);
        euint32 countryCode = FHE.fromExternal(encCountryCode, ccProof);

        // Clamp requested amount to pool bounds
        euint64 clampedAmount = FHE.select(FHE.gt(requestedAmount, pool.perAwardMaximumUSD),
            pool.perAwardMaximumUSD, requestedAmount);
        clampedAmount = FHE.select(FHE.lt(clampedAmount, pool.perAwardMinimumUSD),
            pool.perAwardMinimumUSD, clampedAmount);

        applicationId = keccak256(abi.encodePacked(msg.sender, poolId, block.timestamp));

        applications[applicationId] = Application({
            poolId: poolId,
            applicant: msg.sender,
            status: ApplicationStatus.SUBMITTED,
            requestedAmountUSD: clampedAmount,
            awardedAmountUSD: FHE.asEuint64(0),
            financialNeedScore: financialNeed,
            academicMeritScore: academicMerit,
            researchScore: researchScore,
            committeeRankScore: FHE.asEuint64(0),
            nationalityQuotaUsed: FHE.asEuint64(0),
            countryCode: countryCode,
            submittedAt: block.timestamp,
            financialVerified: false,
            academicVerified: false
        });

        FHE.allowThis(clampedAmount); FHE.allow(clampedAmount, msg.sender);
        FHE.allowThis(financialNeed); FHE.allow(financialNeed, msg.sender);
        FHE.allowThis(academicMerit); FHE.allow(academicMerit, msg.sender);
        FHE.allowThis(researchScore); FHE.allow(researchScore, msg.sender);
        FHE.allowThis(countryCode); FHE.allow(countryCode, msg.sender);
        FHE.allowThis(applications[applicationId].awardedAmountUSD);
        FHE.allow(applications[applicationId].awardedAmountUSD, msg.sender);
        FHE.allowThis(applications[applicationId].committeeRankScore);
        FHE.allowThis(applications[applicationId].nationalityQuotaUsed);

        emit ApplicationSubmitted(applicationId, poolId);
    }

    function submitCommitteeScore(
        bytes32 applicationId,
        externalEuint64 encScore, bytes calldata sProof,
        externalEuint64 encFinancialWeight, bytes calldata fwProof,
        externalEuint64 encMeritWeight, bytes calldata mwProof
    ) external {
        require(authorizedCommitteeMember[msg.sender], "Not committee member");
        Application storage app = applications[applicationId];
        require(app.status == ApplicationStatus.UNDER_REVIEW, "Not in review");

        euint64 score = FHE.fromExternal(encScore, sProof);
        euint64 financialWeight = FHE.fromExternal(encFinancialWeight, fwProof);
        euint64 meritWeight = FHE.fromExternal(encMeritWeight, mwProof);

        committeeScores[applicationId].push(CommitteeScore({
            reviewer: msg.sender,
            score: score,
            financialWeight: financialWeight,
            meritWeight: meritWeight,
            submitted: true
        }));

        // Update composite score
        euint64 weightedScore = FHE.div(
            FHE.add(FHE.mul(app.financialNeedScore, financialWeight),
                    FHE.mul(app.academicMeritScore, meritWeight)),
            10000
        );
        app.committeeRankScore = FHE.add(app.committeeRankScore, weightedScore);

        FHE.allowThis(score); FHE.allowThis(financialWeight); FHE.allowThis(meritWeight);
        FHE.allowThis(app.committeeRankScore);
        emit CommitteeScoreSubmitted(applicationId, msg.sender);
    }

    function awardScholarship(bytes32 applicationId) external onlyOwner nonReentrant {
        Application storage app = applications[applicationId];
        require(app.status == ApplicationStatus.SHORTLISTED, "Not shortlisted");

        ScholarshipPool storage pool = pools[app.poolId];
        require(pool.active, "Pool not active");
        require(block.timestamp >= pool.awardDate, "Not award date");

        // Check remaining budget
        ebool hasBudget = FHE.ge(pool.remainingFundingUSD, app.requestedAmountUSD);
        euint64 actualAward = FHE.select(hasBudget, app.requestedAmountUSD, pool.remainingFundingUSD);

        app.awardedAmountUSD = actualAward;
        app.status = ApplicationStatus.AWARDED;

        pool.remainingFundingUSD = FHE.sub(pool.remainingFundingUSD, actualAward);
        pool.awardedCount = FHE.add(pool.awardedCount, FHE.asEuint32(1));

        _totalScholarshipsAwarded = FHE.add(_totalScholarshipsAwarded, actualAward);
        _totalApplicantsServed = FHE.add(_totalApplicantsServed, FHE.asEuint64(1));

        if (pool.scholarshipType == ScholarshipType.NEED_BASED) {
            _needBasedFundingDeployed = FHE.add(_needBasedFundingDeployed, actualAward);
            FHE.allowThis(_needBasedFundingDeployed);
        }

        FHE.allowThis(actualAward); FHE.allow(actualAward, app.applicant);
        FHE.allowThis(pool.remainingFundingUSD);
        FHE.allowThis(pool.awardedCount);
        FHE.allowThis(_totalScholarshipsAwarded);
        FHE.allowThis(_totalApplicantsServed);
        FHE.allowTransient(actualAward, app.applicant);

        emit ScholarshipAwarded(applicationId, app.poolId);
    }

    function grantCommitteeMembership(address member) external onlyOwner {
        authorizedCommitteeMember[member] = true;
    }

    function allowPoolStatsView(bytes32 poolId, address viewer) external onlyOwner {
        ScholarshipPool storage pool = pools[poolId];
        FHE.allow(pool.totalFundingUSD, viewer);
        FHE.allow(pool.remainingFundingUSD, viewer);
        FHE.allow(pool.awardedCount, viewer);
        FHE.allow(_totalScholarshipsAwarded, viewer);
    }
}
