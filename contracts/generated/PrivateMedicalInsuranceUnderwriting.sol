// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMedicalInsuranceUnderwriting
/// @notice Medical insurance underwriting with encrypted health risk scores,
///         confidential premium calculations, and private claims processing.
///         Health data never revealed on-chain; only encrypted actuarial decisions.
contract PrivateMedicalInsuranceUnderwriting is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum PolicyStatus { PENDING, ACTIVE, LAPSED, CANCELLED, CLAIMED }
    enum RiskTier { LOW, MEDIUM, HIGH, DECLINED }

    struct PolicyHolder {
        euint64 annualPremiumUSD;      // encrypted premium
        euint64 coverageLimitUSD;      // encrypted coverage amount
        euint64 deductibleUSD;         // encrypted deductible
        euint64 lifetimeClaimsUSD;     // encrypted lifetime claims paid
        euint32 riskScore;             // encrypted actuarial risk score (0-1000)
        euint8 riskTier;               // encrypted risk tier classification
        euint8 ageGroup;               // encrypted age band (0=<30, 1=30-50, 2=50-65, 3=65+)
        PolicyStatus status;
        uint256 policyStartDate;
        uint256 policyEndDate;
        bool exists;
    }

    struct ClaimRequest {
        address policyholder;
        euint64 claimedAmountUSD;      // encrypted claim amount
        euint64 approvedAmountUSD;     // encrypted approved amount
        euint64 deductibleApplied;     // encrypted deductible portion
        euint64 netPayableUSD;         // encrypted net payout
        euint8 diagnosisCodeEncrypted; // encrypted ICD code category
        uint256 submittedAt;
        bool adjudicated;
        bool approved;
    }

    struct UnderwritingRule {
        euint64 maxCoverageForTier;    // encrypted max coverage by risk tier
        euint64 basePremiumRateBps;    // encrypted base premium rate
        euint64 riskLoadingBps;        // encrypted risk loading factor
        bool active;
    }

    mapping(address => PolicyHolder) private policies;
    mapping(uint256 => ClaimRequest) private claims;
    mapping(uint8 => UnderwritingRule) private underwritingRules; // indexed by risk tier
    mapping(address => bool) public isUnderwriter;
    mapping(address => bool) public isClaimsAdjudicator;

    uint256 public claimCount;
    euint64 private _totalPremiumsCollected;
    euint64 private _totalClaimsPaid;
    euint64 private _totalReserveRequirement;
    euint64 private _lossRatioTracker;

    event PolicyIssued(address indexed holder, uint256 startDate, uint256 endDate);
    event PremiumUpdated(address indexed holder);
    event ClaimSubmitted(uint256 indexed claimId, address indexed holder);
    event ClaimAdjudicated(uint256 indexed claimId, bool approved);
    event PolicyCancelled(address indexed holder);
    event ReserveUpdated();

    constructor() Ownable(msg.sender) {
        _totalPremiumsCollected = FHE.asEuint64(0);
        _totalClaimsPaid = FHE.asEuint64(0);
        _totalReserveRequirement = FHE.asEuint64(0);
        _lossRatioTracker = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumsCollected);
        FHE.allowThis(_totalClaimsPaid);
        FHE.allowThis(_totalReserveRequirement);
        FHE.allowThis(_lossRatioTracker);
        isUnderwriter[msg.sender] = true;
        isClaimsAdjudicator[msg.sender] = true;
    }

    modifier onlyUnderwriter() { require(isUnderwriter[msg.sender], "Not underwriter"); _; }
    modifier onlyAdjudicator() { require(isClaimsAdjudicator[msg.sender], "Not adjudicator"); _; }

    function setUnderwritingRule(
        uint8 riskTier,
        externalEuint64 encMaxCoverage, bytes calldata mcProof,
        externalEuint64 encBasePremium, bytes calldata bpProof,
        externalEuint64 encRiskLoading, bytes calldata rlProof
    ) external onlyUnderwriter {
        UnderwritingRule storage ur = underwritingRules[riskTier];
        ur.maxCoverageForTier = FHE.fromExternal(encMaxCoverage, mcProof);
        ur.basePremiumRateBps = FHE.fromExternal(encBasePremium, bpProof);
        ur.riskLoadingBps = FHE.fromExternal(encRiskLoading, rlProof);
        ur.active = true;
        FHE.allowThis(ur.maxCoverageForTier);
        FHE.allowThis(ur.basePremiumRateBps);
        FHE.allowThis(ur.riskLoadingBps);
    }

    function issuePolicy(
        address holder,
        externalEuint64 encRiskScore, bytes calldata rsProof,
        externalEuint8 encRiskTier, bytes calldata rtProof,
        externalEuint8 encAgeGroup, bytes calldata agProof,
        externalEuint64 encCoverageRequested, bytes calldata crProof,
        uint256 policyEndDate
    ) external onlyUnderwriter {
        require(!policies[holder].exists || policies[holder].status == PolicyStatus.LAPSED, "Policy active");
        euint64 riskScore64 = FHE.fromExternal(encRiskScore, rsProof);
        euint32 riskScore32 = FHE.asEuint32(FHE.decrypt(riskScore64) > type(uint32).max ? type(uint32).max : uint32(FHE.decrypt(riskScore64)));
        euint8 riskTier = FHE.fromExternal(encRiskTier, rtProof);
        euint8 ageGroup = FHE.fromExternal(encAgeGroup, agProof);
        euint64 coverageReq = FHE.fromExternal(encCoverageRequested, crProof);
        // Get underwriting rule for this tier
        uint8 tierVal = uint8(FHE.decrypt(riskTier));
        require(tierVal < 4, "Invalid tier");
        UnderwritingRule storage ur = underwritingRules[tierVal];
        require(ur.active, "No rule for tier");
        // Cap coverage at max for tier
        ebool withinLimit = FHE.le(coverageReq, ur.maxCoverageForTier);
        euint64 actualCoverage = FHE.select(withinLimit, coverageReq, ur.maxCoverageForTier);
        // Calculate premium: base rate + risk loading on coverage
        euint64 basePremium = FHE.div(FHE.mul(actualCoverage, ur.basePremiumRateBps), 10000);
        euint64 riskLoad = FHE.div(FHE.mul(basePremium, ur.riskLoadingBps), 10000);
        euint64 totalPremium = FHE.add(basePremium, riskLoad);
        // Age loading: >65 adds 30%
        euint64 ageLoad = FHE.select(FHE.eq(ageGroup, FHE.asEuint8(3)),
            FHE.div(FHE.mul(totalPremium, 3000), 10000),
            FHE.asEuint64(0));
        totalPremium = FHE.add(totalPremium, ageLoad);
        // Deductible: 10% of coverage
        euint64 deductible = FHE.div(actualCoverage, 10);
        PolicyHolder storage ph = policies[holder];
        ph.annualPremiumUSD = totalPremium;
        ph.coverageLimitUSD = actualCoverage;
        ph.deductibleUSD = deductible;
        ph.lifetimeClaimsUSD = FHE.asEuint64(0);
        ph.riskScore = riskScore32;
        ph.riskTier = riskTier;
        ph.ageGroup = ageGroup;
        ph.status = PolicyStatus.ACTIVE;
        ph.policyStartDate = block.timestamp;
        ph.policyEndDate = policyEndDate;
        ph.exists = true;
        FHE.allowThis(ph.annualPremiumUSD);
        FHE.allow(ph.annualPremiumUSD, holder);
        FHE.allowThis(ph.coverageLimitUSD);
        FHE.allow(ph.coverageLimitUSD, holder);
        FHE.allowThis(ph.deductibleUSD);
        FHE.allow(ph.deductibleUSD, holder);
        FHE.allowThis(ph.lifetimeClaimsUSD);
        FHE.allow(ph.lifetimeClaimsUSD, holder);
        FHE.allowThis(ph.riskScore);
        FHE.allowThis(ph.riskTier);
        FHE.allow(ph.riskTier, holder);
        FHE.allowThis(ph.ageGroup);
        _totalReserveRequirement = FHE.add(_totalReserveRequirement, actualCoverage);
        FHE.allowThis(_totalReserveRequirement);
        emit PolicyIssued(holder, block.timestamp, policyEndDate);
    }

    function recordPremiumPayment(address holder, externalEuint64 encPayment, bytes calldata pProof) external onlyUnderwriter {
        euint64 payment = FHE.fromExternal(encPayment, pProof);
        _totalPremiumsCollected = FHE.add(_totalPremiumsCollected, payment);
        FHE.allowThis(_totalPremiumsCollected);
    }

    function submitClaim(
        externalEuint64 encClaimAmount, bytes calldata caProof,
        externalEuint8 encDiagnosisCode, bytes calldata dcProof
    ) external nonReentrant returns (uint256 claimId) {
        PolicyHolder storage ph = policies[msg.sender];
        require(ph.exists && ph.status == PolicyStatus.ACTIVE, "No active policy");
        require(block.timestamp <= ph.policyEndDate, "Policy expired");
        euint64 claimAmt = FHE.fromExternal(encClaimAmount, caProof);
        euint8 diagCode = FHE.fromExternal(encDiagnosisCode, dcProof);
        claimId = claimCount++;
        ClaimRequest storage cr = claims[claimId];
        cr.policyholder = msg.sender;
        cr.claimedAmountUSD = claimAmt;
        cr.approvedAmountUSD = FHE.asEuint64(0);
        cr.deductibleApplied = FHE.asEuint64(0);
        cr.netPayableUSD = FHE.asEuint64(0);
        cr.diagnosisCodeEncrypted = diagCode;
        cr.submittedAt = block.timestamp;
        cr.adjudicated = false;
        FHE.allowThis(cr.claimedAmountUSD);
        FHE.allow(cr.claimedAmountUSD, msg.sender);
        FHE.allowThis(cr.diagnosisCodeEncrypted);
        emit ClaimSubmitted(claimId, msg.sender);
    }

    function adjudicateClaim(uint256 claimId, bool approve) external onlyAdjudicator {
        ClaimRequest storage cr = claims[claimId];
        require(!cr.adjudicated, "Already adjudicated");
        PolicyHolder storage ph = policies[cr.policyholder];
        cr.adjudicated = true;
        cr.approved = approve;
        if (approve) {
            // Apply deductible
            ebool claimExceedsDeductible = FHE.gt(cr.claimedAmountUSD, ph.deductibleUSD);
            euint64 deductApplied = FHE.select(claimExceedsDeductible, ph.deductibleUSD, cr.claimedAmountUSD);
            euint64 afterDeductible = FHE.select(claimExceedsDeductible,
                FHE.sub(cr.claimedAmountUSD, ph.deductibleUSD), FHE.asEuint64(0));
            // Cap at coverage limit
            euint64 remainingCoverage = FHE.sub(ph.coverageLimitUSD, ph.lifetimeClaimsUSD);
            ebool withinLimit = FHE.le(afterDeductible, remainingCoverage);
            euint64 approvedAmt = FHE.select(withinLimit, afterDeductible, remainingCoverage);
            cr.approvedAmountUSD = approvedAmt;
            cr.deductibleApplied = deductApplied;
            cr.netPayableUSD = approvedAmt;
            ph.lifetimeClaimsUSD = FHE.add(ph.lifetimeClaimsUSD, approvedAmt);
            _totalClaimsPaid = FHE.add(_totalClaimsPaid, approvedAmt);
            FHE.allowThis(cr.approvedAmountUSD);
            FHE.allow(cr.approvedAmountUSD, cr.policyholder);
            FHE.allowThis(cr.netPayableUSD);
            FHE.allow(cr.netPayableUSD, cr.policyholder);
            FHE.allowThis(ph.lifetimeClaimsUSD);
            FHE.allow(ph.lifetimeClaimsUSD, cr.policyholder);
            FHE.allowThis(_totalClaimsPaid);
            FHE.allowTransient(cr.netPayableUSD, cr.policyholder);
        }
        emit ClaimAdjudicated(claimId, approve);
    }

    function cancelPolicy(address holder) external onlyUnderwriter {
        policies[holder].status = PolicyStatus.CANCELLED;
        emit PolicyCancelled(holder);
    }

    function allowPortfolioStats(address reinsurer) external onlyOwner {
        FHE.allow(_totalPremiumsCollected, reinsurer);
        FHE.allow(_totalClaimsPaid, reinsurer);
        FHE.allow(_totalReserveRequirement, reinsurer);
    }

    function addUnderwriter(address u) external onlyOwner { isUnderwriter[u] = true; }
    function addAdjudicator(address a) external onlyOwner { isClaimsAdjudicator[a] = true; }
}
