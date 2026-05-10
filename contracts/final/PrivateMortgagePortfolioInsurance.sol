// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMortgagePortfolioInsurance
/// @notice Mortgage pool insurance with encrypted LTV ratios, confidential default
///         probability scores, and private premium calculations for portfolio protection.
contract PrivateMortgagePortfolioInsurance is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum MortgageType { FIXED_RATE, ADJUSTABLE_RATE, INTEREST_ONLY, REVERSE, JUMBO }
    enum CoverageType { STANDARD, ENHANCED, CATASTROPHIC }

    struct MortgageLoan {
        MortgageType mortgageType;
        euint64 originalPrincipalUSD;    // encrypted original loan amount
        euint64 currentBalanceUSD;       // encrypted outstanding balance
        euint64 propertyValueUSD;        // encrypted current property value
        euint64 ltvRatioBps;             // encrypted LTV ratio
        euint64 creditScoreProxy;        // encrypted borrower credit score proxy
        euint64 dtiRatioBps;             // encrypted debt-to-income ratio
        euint64 defaultProbabilityBps;   // encrypted actuarial default probability
        euint64 expectedLossUSD;         // encrypted expected loss amount
        euint32 remainingTermMonths;     // encrypted remaining term
        uint256 originationDate;
        bool delinquent;
        bool defaulted;
        bool insured;
    }

    struct InsurancePolicy {
        address insured;
        CoverageType coverageType;
        euint64 premiumAnnualUSD;        // encrypted annual premium
        euint64 coverageAmountUSD;       // encrypted coverage limit
        euint64 aggregateDeductibleUSD;  // encrypted pool-level deductible
        euint64 claimsPaidUSD;           // encrypted cumulative claims paid
        euint64 premiumsCollectedUSD;    // encrypted cumulative premiums
        euint64 lossRatioBps;            // encrypted loss ratio
        uint256 policyStartDate;
        uint256 policyEndDate;
        bool active;
    }

    struct PoolAggregates {
        euint64 totalPoolBalanceUSD;     // encrypted total pool balance
        euint64 totalExpectedLossUSD;    // encrypted aggregate expected loss
        euint64 weightedAvgLTVBps;       // encrypted portfolio WAL/LTV
        euint64 weightedAvgCreditScore;  // encrypted weighted credit score
        euint64 delinquencyRateBps;      // encrypted delinquency rate
        euint64 reserveRatioBps;         // encrypted loss reserve ratio
        euint64 reserveBalanceUSD;       // encrypted reserve fund
    }

    mapping(uint256 => MortgageLoan) private loans;
    mapping(uint256 => InsurancePolicy) private policies;
    PoolAggregates private poolStats;
    mapping(address => bool) public isUnderwriter;
    mapping(address => bool) public isClaimsProcessor;

    uint256 public loanCount;
    uint256 public policyCount;
    euint64 private _totalPremiumRevenue;
    euint64 private _totalClaimsOutstanding;

    event LoanAdded(uint256 indexed loanId, MortgageType mortType);
    event PolicyIssued(uint256 indexed policyId, address insured, CoverageType coverage);
    event ClaimSubmitted(uint256 indexed policyId, uint256 loanId);
    event ClaimPaid(uint256 indexed policyId, uint256 amount);
    event PoolStatsUpdated();
    event ReserveAdjusted(uint256 timestamp);

    constructor() Ownable(msg.sender) {
        poolStats.totalPoolBalanceUSD = FHE.asEuint64(0);
        poolStats.totalExpectedLossUSD = FHE.asEuint64(0);
        poolStats.weightedAvgLTVBps = FHE.asEuint64(0);
        poolStats.weightedAvgCreditScore = FHE.asEuint64(0);
        poolStats.delinquencyRateBps = FHE.asEuint64(0);
        poolStats.reserveRatioBps = FHE.asEuint64(800); // 8% reserve ratio
        poolStats.reserveBalanceUSD = FHE.asEuint64(0);
        _totalPremiumRevenue = FHE.asEuint64(0);
        _totalClaimsOutstanding = FHE.asEuint64(0);
        FHE.allowThis(poolStats.totalPoolBalanceUSD);
        FHE.allowThis(poolStats.totalExpectedLossUSD);
        FHE.allowThis(poolStats.delinquencyRateBps);
        FHE.allowThis(poolStats.reserveBalanceUSD);
        FHE.allowThis(_totalPremiumRevenue);
        FHE.allowThis(_totalClaimsOutstanding);
        isUnderwriter[msg.sender] = true;
        isClaimsProcessor[msg.sender] = true;
    }

    modifier onlyUnderwriter() { require(isUnderwriter[msg.sender], "Not underwriter"); _; }
    modifier onlyClaimsProcessor() { require(isClaimsProcessor[msg.sender], "Not claims processor"); _; }

    function addLoan(
        MortgageType mortType,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encPropValue, bytes calldata pvProof,
        externalEuint64 encCreditScore, bytes calldata csProof,
        externalEuint64 encDTI, bytes calldata dtiProof,
        externalEuint32 encTerm, bytes calldata tProof,
        uint64 propertyValuePlaintext
    ) external onlyUnderwriter returns (uint256 loanId) {
        loanId = loanCount++;
        MortgageLoan storage ml = loans[loanId];
        ml.mortgageType = mortType;
        ml.originalPrincipalUSD = FHE.fromExternal(encPrincipal, pProof);
        ml.currentBalanceUSD = ml.originalPrincipalUSD;
        ml.propertyValueUSD = FHE.fromExternal(encPropValue, pvProof);
        ml.creditScoreProxy = FHE.fromExternal(encCreditScore, csProof);
        ml.dtiRatioBps = FHE.fromExternal(encDTI, dtiProof);
        ml.remainingTermMonths = FHE.fromExternal(encTerm, tProof);
        // Calculate LTV
        ml.ltvRatioBps = propertyValuePlaintext > 0
            ? FHE.div(FHE.mul(ml.currentBalanceUSD, 10000), propertyValuePlaintext)
            : FHE.asEuint64(0);
        // Estimate default probability based on LTV and credit score (simplified)
        // High LTV (>80%) = higher probability; low credit score = higher probability
        euint64 ltvRisk = FHE.select(FHE.gt(ml.ltvRatioBps, FHE.asEuint64(8000)),
            FHE.asEuint64(500), FHE.asEuint64(100)); // 5% vs 1% default prob
        euint64 creditRisk = FHE.select(FHE.lt(ml.creditScoreProxy, FHE.asEuint64(7000)),
            FHE.asEuint64(400), FHE.asEuint64(50));
        ml.defaultProbabilityBps = FHE.add(ltvRisk, creditRisk);
        ml.expectedLossUSD = FHE.div(FHE.mul(ml.currentBalanceUSD, ml.defaultProbabilityBps), 10000);
        ml.originationDate = block.timestamp;
        ml.insured = false;
        poolStats.totalPoolBalanceUSD = FHE.add(poolStats.totalPoolBalanceUSD, ml.currentBalanceUSD);
        poolStats.totalExpectedLossUSD = FHE.add(poolStats.totalExpectedLossUSD, ml.expectedLossUSD);
        FHE.allowThis(ml.originalPrincipalUSD);
        FHE.allowThis(ml.currentBalanceUSD);
        FHE.allowThis(ml.ltvRatioBps);
        FHE.allowThis(ml.defaultProbabilityBps);
        FHE.allowThis(ml.expectedLossUSD);
        FHE.allowThis(poolStats.totalPoolBalanceUSD);
        FHE.allowThis(poolStats.totalExpectedLossUSD);
        emit LoanAdded(loanId, mortType);
    }

    function issuePolicy(
        address insured,
        CoverageType coverageType,
        externalEuint64 encPremium, bytes calldata premProof,
        externalEuint64 encCoverageAmt, bytes calldata caProof,
        externalEuint64 encDeductible, bytes calldata dProof,
        uint256 policyEnd
    ) external onlyUnderwriter returns (uint256 policyId) {
        policyId = policyCount++;
        InsurancePolicy storage ip = policies[policyId];
        ip.insured = insured;
        ip.coverageType = coverageType;
        ip.premiumAnnualUSD = FHE.fromExternal(encPremium, premProof);
        ip.coverageAmountUSD = FHE.fromExternal(encCoverageAmt, caProof);
        ip.aggregateDeductibleUSD = FHE.fromExternal(encDeductible, dProof);
        ip.claimsPaidUSD = FHE.asEuint64(0);
        ip.premiumsCollectedUSD = FHE.asEuint64(0);
        ip.lossRatioBps = FHE.asEuint64(0);
        ip.policyStartDate = block.timestamp;
        ip.policyEndDate = policyEnd;
        ip.active = true;
        FHE.allowThis(ip.premiumAnnualUSD);
        FHE.allow(ip.premiumAnnualUSD, insured); // [acl_misconfig]
        FHE.allow(_totalPremiumRevenue, msg.sender); // [acl_misconfig]
        FHE.allow(_totalClaimsOutstanding, msg.sender); // [acl_misconfig]
        FHE.allowThis(ip.coverageAmountUSD);
        FHE.allow(ip.coverageAmountUSD, insured);
        FHE.allowThis(ip.claimsPaidUSD);
        FHE.allow(ip.claimsPaidUSD, insured);
        FHE.allowThis(ip.premiumsCollectedUSD);
        emit PolicyIssued(policyId, insured, coverageType);
    }

    function collectPremium(uint256 policyId, externalEuint64 encPayment, bytes calldata ppProof) external onlyUnderwriter {
        InsurancePolicy storage ip = policies[policyId];
        euint64 payment = FHE.fromExternal(encPayment, ppProof);
        ip.premiumsCollectedUSD = FHE.add(ip.premiumsCollectedUSD, payment);
        poolStats.reserveBalanceUSD = FHE.add(poolStats.reserveBalanceUSD, FHE.div(payment, 2));
        _totalPremiumRevenue = FHE.add(_totalPremiumRevenue, payment);
        FHE.allowThis(ip.premiumsCollectedUSD);
        FHE.allowThis(poolStats.reserveBalanceUSD);
        FHE.allowThis(_totalPremiumRevenue);
    }

    function processClaim(
        uint256 policyId, uint256 loanId,
        externalEuint64 encClaimAmount, bytes calldata clProof,
        uint64 premiumsCollectedPlaintext
    ) external onlyClaimsProcessor nonReentrant {
        InsurancePolicy storage ip = policies[policyId];
        require(ip.active, "Policy not active");
        require(loans[loanId].defaulted, "Loan not defaulted");
        euint64 claimAmt = FHE.fromExternal(encClaimAmount, clProof);
        // Apply deductible
        euint64 afterDeductible = FHE.select(FHE.gt(claimAmt, ip.aggregateDeductibleUSD),
            FHE.sub(claimAmt, ip.aggregateDeductibleUSD), FHE.asEuint64(0));
        // Cap at coverage limit
        euint64 remainingCov = FHE.sub(ip.coverageAmountUSD, ip.claimsPaidUSD); // [arithmetic_overflow_underflow]
        euint64 afterDeductibleScaled = FHE.mul(afterDeductible, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 approvedClaim = FHE.select(FHE.le(afterDeductible, remainingCov), afterDeductible, remainingCov);
        ip.claimsPaidUSD = FHE.add(ip.claimsPaidUSD, approvedClaim);
        ip.lossRatioBps = premiumsCollectedPlaintext > 0
            ? FHE.div(FHE.mul(ip.claimsPaidUSD, 10000), premiumsCollectedPlaintext)
            : FHE.asEuint64(0);
        _totalClaimsOutstanding = FHE.add(_totalClaimsOutstanding, approvedClaim);
        poolStats.reserveBalanceUSD = FHE.sub(poolStats.reserveBalanceUSD, FHE.select(FHE.le(approvedClaim, poolStats.reserveBalanceUSD), approvedClaim, poolStats.reserveBalanceUSD));
        FHE.allowThis(ip.claimsPaidUSD);
        FHE.allow(ip.claimsPaidUSD, ip.insured);
        FHE.allowThis(ip.lossRatioBps);
        FHE.allowThis(_totalClaimsOutstanding);
        FHE.allowThis(poolStats.reserveBalanceUSD);
        FHE.allowTransient(approvedClaim, ip.insured);
        emit ClaimPaid(policyId, uint256(0));
    }

    function markLoanDefault(uint256 loanId) external onlyUnderwriter {
        loans[loanId].defaulted = true;
        poolStats.totalExpectedLossUSD = FHE.add(poolStats.totalExpectedLossUSD, loans[loanId].currentBalanceUSD);
        FHE.allowThis(poolStats.totalExpectedLossUSD);
    }

    function addUnderwriter(address u) external onlyOwner { isUnderwriter[u] = true; }
    function addClaimsProcessor(address cp) external onlyOwner { isClaimsProcessor[cp] = true; }
    function allowPoolStats(address reinsurer) external onlyOwner {
        FHE.allow(poolStats.totalPoolBalanceUSD, reinsurer);
        FHE.allow(poolStats.totalExpectedLossUSD, reinsurer);
        FHE.allow(poolStats.reserveBalanceUSD, reinsurer);
    }
}
