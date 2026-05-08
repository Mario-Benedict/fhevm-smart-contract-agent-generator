// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateDebtSecuritizationSPV
/// @notice Special Purpose Vehicle (SPV) for securitizing loan portfolios.
///         Encrypted loan-level data, confidential tranche waterfalls, and
///         private credit enhancement mechanisms for asset-backed securities.
contract PrivateDebtSecuritizationSPV is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {

    enum TrancheRating { AAA, AA, A, BBB, BB, EQUITY }
    enum LoanType { MORTGAGE, AUTO, STUDENT, CREDIT_CARD, COMMERCIAL }

    struct Tranche {
        TrancheRating rating;
        euint64 principalBalance;      // encrypted tranche principal
        euint64 couponRateBps;         // encrypted coupon rate
        euint64 creditEnhancementBps;  // encrypted over-collateralization buffer
        euint64 currentOC_Ratio;       // encrypted O/C ratio
        euint64 accruedInterest;       // encrypted accrued interest
        euint64 distributedPrincipal;  // encrypted cumulative principal returned
        uint8 seniorityRank;           // 0 = most senior
        bool locked;
        bool active;
    }

    struct LoanAsset {
        LoanType loanType;
        euint64 originalPrincipal;     // encrypted original loan amount
        euint64 remainingBalance;      // encrypted outstanding balance
        euint64 interestRateBps;       // encrypted interest rate
        euint64 monthlyPayment;        // encrypted scheduled payment
        euint64 creditScoreProxy;      // encrypted borrower credit proxy
        euint32 remainingTermMonths;   // encrypted months remaining
        euint8 delinquencyStatusDays;  // encrypted days past due (0, 30, 60, 90)
        bool defaulted;
        bool active;
    }

    struct DistributionPeriod {
        euint64 totalCollected;        // encrypted total cash collected
        euint64 totalDistributed;      // encrypted total distributed to tranches
        euint64 reserveAccountBalance; // encrypted reserve after distribution
        uint256 periodTimestamp;
        bool processed;
    }

    mapping(uint256 => Tranche) private tranches;
    mapping(uint256 => LoanAsset) private loans;
    mapping(address => mapping(uint256 => euint64)) private trancheHoldings; // investor => trancheId => balance
    mapping(uint256 => DistributionPeriod) private periods;
    mapping(address => bool) public isServicer;
    mapping(address => bool) public isTrustee;
    mapping(address => bool) public isInvestor;

    uint256 public trancheCount;
    uint256 public loanCount;
    uint256 public periodCount;
    euint64 private _totalPoolBalance;     // encrypted total loan pool
    euint64 private _totalDefaultedUSD;    // encrypted total defaulted
    euint64 private _reserveAccountBalance; // encrypted reserve fund
    euint64 private _spvFeeRateBps;         // encrypted management fee

    event TrancheCreated(uint256 indexed id, TrancheRating rating);
    event LoanAdded(uint256 indexed loanId, LoanType loanType);
    event LoanPaymentRecorded(uint256 indexed loanId);
    event LoanDefaulted(uint256 indexed loanId);
    event DistributionProcessed(uint256 indexed periodId);
    event InvestorSharesMinted(address indexed investor, uint256 indexed trancheId);

    constructor(externalEuint64 encFeeRate, bytes memory frProof) Ownable(msg.sender) {
        _spvFeeRateBps = FHE.fromExternal(encFeeRate, frProof);
        _totalPoolBalance = FHE.asEuint64(0);
        _totalDefaultedUSD = FHE.asEuint64(0);
        _reserveAccountBalance = FHE.asEuint64(0);
        FHE.allowThis(_spvFeeRateBps);
        FHE.allowThis(_totalPoolBalance);
        FHE.allowThis(_totalDefaultedUSD);
        FHE.allowThis(_reserveAccountBalance);
        isServicer[msg.sender] = true;
        isTrustee[msg.sender] = true;
    }

    modifier onlyServicer() { require(isServicer[msg.sender], "Not servicer"); _; }
    modifier onlyTrustee() { require(isTrustee[msg.sender], "Not trustee"); _; }

    function createTranche(
        TrancheRating rating,
        uint8 seniorityRank,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encCoupon, bytes calldata cProof,
        externalEuint64 encCreditEnhancement, bytes calldata ceProof
    ) external onlyTrustee returns (uint256 id) {
        id = trancheCount++;
        Tranche storage t = tranches[id];
        t.rating = rating;
        t.seniorityRank = seniorityRank;
        t.principalBalance = FHE.fromExternal(encPrincipal, pProof);
        t.couponRateBps = FHE.fromExternal(encCoupon, cProof);
        t.creditEnhancementBps = FHE.fromExternal(encCreditEnhancement, ceProof);
        t.currentOC_Ratio = FHE.asEuint64(10000); // start at 100%
        t.accruedInterest = FHE.asEuint64(0);
        t.distributedPrincipal = FHE.asEuint64(0);
        t.active = true;
        FHE.allowThis(t.principalBalance);
        FHE.allowThis(t.couponRateBps);
        FHE.allowThis(t.creditEnhancementBps);
        FHE.allowThis(t.currentOC_Ratio);
        FHE.allowThis(t.accruedInterest);
        FHE.allowThis(t.distributedPrincipal);
        emit TrancheCreated(id, rating);
    }

    function addLoan(
        LoanType loanType,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encRate, bytes calldata rProof,
        externalEuint64 encPayment, bytes calldata payProof,
        externalEuint64 encCreditScore, bytes calldata csProof,
        externalEuint32 encTerm, bytes calldata tProof
    ) external onlyServicer returns (uint256 loanId) {
        loanId = loanCount++;
        LoanAsset storage la = loans[loanId];
        la.loanType = loanType;
        la.originalPrincipal = FHE.fromExternal(encPrincipal, pProof);
        la.remainingBalance = la.originalPrincipal;
        la.interestRateBps = FHE.fromExternal(encRate, rProof);
        la.monthlyPayment = FHE.fromExternal(encPayment, payProof);
        la.creditScoreProxy = FHE.fromExternal(encCreditScore, csProof);
        la.remainingTermMonths = FHE.fromExternal(encTerm, tProof);
        la.delinquencyStatusDays = FHE.asEuint8(0);
        la.active = true;
        _totalPoolBalance = FHE.add(_totalPoolBalance, la.originalPrincipal);
        FHE.allowThis(la.originalPrincipal);
        FHE.allowThis(la.remainingBalance);
        FHE.allowThis(la.interestRateBps);
        FHE.allowThis(la.monthlyPayment);
        FHE.allowThis(la.creditScoreProxy);
        FHE.allowThis(la.remainingTermMonths);
        FHE.allowThis(la.delinquencyStatusDays);
        FHE.allowThis(_totalPoolBalance);
        emit LoanAdded(loanId, loanType);
    }

    function recordLoanPayment(
        uint256 loanId,
        externalEuint64 encPaymentReceived, bytes calldata prProof
    ) external onlyServicer {
        LoanAsset storage la = loans[loanId];
        require(la.active && !la.defaulted, "Loan not active");
        euint64 payment = FHE.fromExternal(encPaymentReceived, prProof);
        // Calculate interest portion
        euint64 interestPortion = FHE.div(FHE.mul(la.remainingBalance, la.interestRateBps), 120000); // monthly
        ebool paymentCoversInterest = FHE.ge(payment, interestPortion);
        euint64 principalPortion = FHE.select(paymentCoversInterest,
            FHE.sub(payment, interestPortion), FHE.asEuint64(0));
        la.remainingBalance = FHE.sub(la.remainingBalance,
            FHE.select(FHE.le(principalPortion, la.remainingBalance), principalPortion, la.remainingBalance));
        la.remainingTermMonths = FHE.sub(la.remainingTermMonths,
            FHE.select(FHE.gt(la.remainingTermMonths, FHE.asEuint32(0)), FHE.asEuint32(1), FHE.asEuint32(0)));
        la.delinquencyStatusDays = FHE.asEuint8(0); // payment made, clear delinquency
        _reserveAccountBalance = FHE.add(_reserveAccountBalance, payment);
        FHE.allowThis(la.remainingBalance);
        FHE.allowThis(la.remainingTermMonths);
        FHE.allowThis(la.delinquencyStatusDays);
        FHE.allowThis(_reserveAccountBalance);
        emit LoanPaymentRecorded(loanId);
    }

    function markLoanDelinquent(
        uint256 loanId,
        externalEuint8 encDaysPastDue, bytes calldata dpdProof
    ) external onlyServicer {
        LoanAsset storage la = loans[loanId];
        euint8 dpd = FHE.fromExternal(encDaysPastDue, dpdProof);
        la.delinquencyStatusDays = dpd;
        // Auto-default at 90+ days
        ebool isDefault = FHE.ge(dpd, FHE.asEuint8(90));
        if (FHE.decrypt(isDefault)) {
            la.defaulted = true;
            _totalDefaultedUSD = FHE.add(_totalDefaultedUSD, la.remainingBalance);
            _totalPoolBalance = FHE.sub(_totalPoolBalance, la.remainingBalance);
            FHE.allowThis(_totalDefaultedUSD);
            FHE.allowThis(_totalPoolBalance);
            emit LoanDefaulted(loanId);
        }
        FHE.allowThis(la.delinquencyStatusDays);
    }

    function processDistribution(
        externalEuint64 encTotalCollected, bytes calldata tcProof
    ) external onlyTrustee whenNotPaused returns (uint256 periodId) {
        euint64 collected = FHE.fromExternal(encTotalCollected, tcProof);
        // Deduct SPV fee
        euint64 feeAmount = FHE.div(FHE.mul(collected, _spvFeeRateBps), 10000);
        euint64 distributable = FHE.sub(collected, feeAmount);
        // Waterfall: distribute senior tranches first
        euint64 remaining = distributable;
        for (uint256 i = 0; i < trancheCount && FHE.decrypt(FHE.gt(remaining, FHE.asEuint64(0))); i++) {
            // Find tranche by seniority rank (simple sequential distribution)
            Tranche storage t = tranches[i];
            if (!t.active || t.locked) continue;
            euint64 trancheInterest = FHE.div(FHE.mul(t.principalBalance, t.couponRateBps), 120000);
            euint64 distAmt = FHE.select(FHE.ge(remaining, trancheInterest), trancheInterest, remaining);
            t.accruedInterest = FHE.add(t.accruedInterest, distAmt);
            remaining = FHE.sub(remaining, distAmt);
            FHE.allowThis(t.accruedInterest);
        }
        periodId = periodCount++;
        periods[periodId] = DistributionPeriod({
            totalCollected: collected,
            totalDistributed: FHE.sub(distributable, remaining),
            reserveAccountBalance: remaining,
            periodTimestamp: block.timestamp,
            processed: true
        });
        _reserveAccountBalance = FHE.add(_reserveAccountBalance, remaining);
        FHE.allowThis(periods[periodId].totalCollected);
        FHE.allowThis(periods[periodId].totalDistributed);
        FHE.allowThis(periods[periodId].reserveAccountBalance);
        FHE.allowThis(_reserveAccountBalance);
        emit DistributionProcessed(periodId);
    }

    function mintInvestorShares(
        address investor,
        uint256 trancheId,
        externalEuint64 encAmount, bytes calldata aProof
    ) external onlyTrustee {
        require(isInvestor[investor], "Not approved investor");
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        trancheHoldings[investor][trancheId] = FHE.add(trancheHoldings[investor][trancheId], amount);
        FHE.allowThis(trancheHoldings[investor][trancheId]);
        FHE.allow(trancheHoldings[investor][trancheId], investor);
        emit InvestorSharesMinted(investor, trancheId);
    }

    function allowPoolStats(address ratingAgency) external onlyOwner {
        FHE.allow(_totalPoolBalance, ratingAgency);
        FHE.allow(_totalDefaultedUSD, ratingAgency);
        FHE.allow(_reserveAccountBalance, ratingAgency);
    }

    function addServicer(address s) external onlyOwner { isServicer[s] = true; }
    function addTrustee(address t) external onlyOwner { isTrustee[t] = true; }
    function addInvestor(address i) external onlyOwner { isInvestor[i] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
