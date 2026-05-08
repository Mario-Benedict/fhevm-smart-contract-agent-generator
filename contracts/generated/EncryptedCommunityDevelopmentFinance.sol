// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCommunityDevelopmentFinance
/// @notice CDFI (Community Development Finance Institution) loan fund:
///         encrypted applicant income scores, encrypted DSCR, encrypted loan amounts,
///         and private community impact score weighting.
contract EncryptedCommunityDevelopmentFinance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LoanApplication {
        address applicant;
        string projectDescription;
        euint64 requestedAmountUSD;  // encrypted loan amount requested
        euint64 annualIncomeUSD;     // encrypted applicant income
        euint64 dscrScore;           // encrypted Debt Service Coverage Ratio (scaled 1000)
        euint64 impactScore;         // encrypted community impact score (0-1000)
        euint64 approvedAmount;      // encrypted approved amount
        euint64 interestRateBps;     // encrypted interest rate
        uint8 riskTier;              // 1=low, 2=medium, 3=high (public)
        bool approved;
        bool disbursed;
    }

    struct LoanRepayment {
        uint256 loanId;
        euint64 principalPaid;    // encrypted principal portion
        euint64 interestPaid;     // encrypted interest portion
        euint64 remainingBalance; // encrypted remaining balance
        uint256 paymentDate;
    }

    struct CommunityMetrics {
        euint64 jobsCreated;       // encrypted jobs created metric
        euint64 lowIncomeServed;   // encrypted # low-income beneficiaries
        euint64 housingUnits;      // encrypted affordable housing units
        uint256 reportingPeriod;
    }

    mapping(uint256 => LoanApplication) private loans;
    mapping(uint256 => LoanRepayment[]) private repayments;
    mapping(uint256 => CommunityMetrics) private metrics;
    uint256 public loanCount;
    uint256 public metricsCount;
    euint64 private _totalLoanBook;
    euint64 private _totalDefaulted;
    euint64 private _availableLoanCapital;
    mapping(address => bool) public isLoanOfficer;

    event ApplicationSubmitted(uint256 indexed id, address applicant);
    event LoanApproved(uint256 indexed id, uint8 riskTier);
    event LoanDisbursed(uint256 indexed id);
    event RepaymentReceived(uint256 indexed loanId);
    event ImpactMetricsSubmitted(uint256 indexed metricsId, uint256 loanId);

    constructor(externalEuint64 encCapital, bytes memory proof) Ownable(msg.sender) {
        _availableLoanCapital = FHE.fromExternal(encCapital, proof);
        _totalLoanBook = FHE.asEuint64(0);
        _totalDefaulted = FHE.asEuint64(0);
        FHE.allowThis(_availableLoanCapital);
        FHE.allowThis(_totalLoanBook);
        FHE.allowThis(_totalDefaulted);
        isLoanOfficer[msg.sender] = true;
    }

    function addLoanOfficer(address lo) external onlyOwner { isLoanOfficer[lo] = true; }

    function applyForLoan(
        string calldata projectDescription,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint64 encIncome, bytes calldata iProof,
        externalEuint64 encDSCR, bytes calldata dProof,
        externalEuint64 encImpact, bytes calldata impProof
    ) external returns (uint256 id) {
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint64 income = FHE.fromExternal(encIncome, iProof);
        euint64 dscr = FHE.fromExternal(encDSCR, dProof);
        euint64 impact = FHE.fromExternal(encImpact, impProof);
        id = loanCount++;
        loans[id] = LoanApplication({
            applicant: msg.sender, projectDescription: projectDescription,
            requestedAmountUSD: amount, annualIncomeUSD: income,
            dscrScore: dscr, impactScore: impact,
            approvedAmount: FHE.asEuint64(0),
            interestRateBps: FHE.asEuint64(0),
            riskTier: 0, approved: false, disbursed: false
        });
        FHE.allowThis(loans[id].requestedAmountUSD);
        FHE.allowThis(loans[id].annualIncomeUSD);
        FHE.allowThis(loans[id].dscrScore);
        FHE.allowThis(loans[id].impactScore);
        FHE.allowThis(loans[id].approvedAmount);
        FHE.allowThis(loans[id].interestRateBps);
        FHE.allow(loans[id].requestedAmountUSD, msg.sender);
        emit ApplicationSubmitted(id, msg.sender);
    }

    function approveLoan(
        uint256 loanId,
        externalEuint64 encApproved, bytes calldata aProof,
        externalEuint64 encRate, bytes calldata rProof,
        uint8 riskTier
    ) external {
        require(isLoanOfficer[msg.sender], "Not loan officer");
        LoanApplication storage loan = loans[loanId];
        require(!loan.approved, "Already processed");
        euint64 approved = FHE.fromExternal(encApproved, aProof);
        euint64 rate = FHE.fromExternal(encRate, rProof);
        // Adjust rate based on impact score: higher impact => lower rate
        ebool highImpact = FHE.ge(loan.impactScore, FHE.asEuint64(700));
        euint64 finalRate = FHE.select(highImpact, FHE.div(rate, 2), rate);
        // Approve within capital available
        ebool withinCap = FHE.le(approved, _availableLoanCapital);
        euint64 finalApproved = FHE.select(withinCap, approved, _availableLoanCapital);
        loan.approvedAmount = finalApproved;
        loan.interestRateBps = finalRate;
        loan.riskTier = riskTier;
        loan.approved = true;
        FHE.allowThis(loan.approvedAmount);
        FHE.allow(loan.approvedAmount, loan.applicant);
        FHE.allowThis(loan.interestRateBps);
        FHE.allow(loan.interestRateBps, loan.applicant);
        emit LoanApproved(loanId, riskTier);
    }

    function disburseLoan(uint256 loanId) external {
        require(isLoanOfficer[msg.sender], "Not loan officer");
        LoanApplication storage loan = loans[loanId];
        require(loan.approved && !loan.disbursed, "Not ready");
        _availableLoanCapital = FHE.sub(_availableLoanCapital, loan.approvedAmount);
        _totalLoanBook = FHE.add(_totalLoanBook, loan.approvedAmount);
        loan.disbursed = true;
        FHE.allow(loan.approvedAmount, loan.applicant);
        FHE.allowThis(_availableLoanCapital);
        FHE.allowThis(_totalLoanBook);
        emit LoanDisbursed(loanId);
    }

    function makeRepayment(
        uint256 loanId,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encInterest, bytes calldata iProof,
        externalEuint64 encRemaining, bytes calldata rProof
    ) external nonReentrant {
        require(loans[loanId].applicant == msg.sender, "Not borrower");
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 interest = FHE.fromExternal(encInterest, iProof);
        euint64 remaining = FHE.fromExternal(encRemaining, rProof);
        repayments[loanId].push(LoanRepayment({
            loanId: loanId, principalPaid: principal, interestPaid: interest,
            remainingBalance: remaining, paymentDate: block.timestamp
        }));
        _totalLoanBook = FHE.sub(_totalLoanBook, principal);
        _availableLoanCapital = FHE.add(_availableLoanCapital, principal);
        uint256 idx = repayments[loanId].length - 1;
        FHE.allowThis(repayments[loanId][idx].principalPaid);
        FHE.allowThis(repayments[loanId][idx].interestPaid);
        FHE.allowThis(repayments[loanId][idx].remainingBalance);
        FHE.allow(repayments[loanId][idx].remainingBalance, msg.sender);
        FHE.allowThis(_totalLoanBook);
        FHE.allowThis(_availableLoanCapital);
        emit RepaymentReceived(loanId);
    }

    function submitImpactMetrics(
        uint256 loanId,
        externalEuint64 encJobs, bytes calldata jProof,
        externalEuint64 encLowIncome, bytes calldata liProof,
        externalEuint64 encHousing, bytes calldata hProof,
        uint256 period
    ) external returns (uint256 metricsId) {
        require(loans[loanId].applicant == msg.sender, "Not borrower");
        euint64 jobs = FHE.fromExternal(encJobs, jProof);
        euint64 lowIncome = FHE.fromExternal(encLowIncome, liProof);
        euint64 housing = FHE.fromExternal(encHousing, hProof);
        metricsId = metricsCount++;
        metrics[metricsId] = CommunityMetrics({
            jobsCreated: jobs, lowIncomeServed: lowIncome,
            housingUnits: housing, reportingPeriod: period
        });
        FHE.allowThis(metrics[metricsId].jobsCreated);
        FHE.allowThis(metrics[metricsId].lowIncomeServed);
        FHE.allowThis(metrics[metricsId].housingUnits);
        FHE.allow(metrics[metricsId].jobsCreated, owner());
        FHE.allow(metrics[metricsId].lowIncomeServed, owner());
        emit ImpactMetricsSubmitted(metricsId, loanId);
    }
}
