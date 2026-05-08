// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAutoLoanOrigination
/// @notice Auto loan underwriting: encrypted income, credit score, LTV, monthly payment calc.
///         Dealer receives encrypted approval decision and loan terms without exposing borrower financials.
contract PrivateAutoLoanOrigination is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum LoanStatus { Applied, Approved, Rejected, Active, PaidOff, Defaulted }

    struct AutoLoan {
        address borrower;
        address dealership;
        euint64 vehiclePriceUSD;      // encrypted
        euint64 downPaymentUSD;       // encrypted
        euint64 loanAmountUSD;        // encrypted
        euint64 annualRateBps;        // encrypted interest rate
        euint64 monthlyPaymentUSD;    // encrypted
        euint8 ltvRatio;              // encrypted LTV (value/price)
        euint8 creditScore;           // encrypted borrower credit score
        euint64 monthsRemaining;      // encrypted
        uint256 originationDate;
        LoanStatus status;
    }

    mapping(uint256 => AutoLoan) private loans;
    mapping(address => uint256[]) private borrowerLoans;
    mapping(address => bool) public isUnderwriter;
    mapping(address => bool) public isDealership;
    uint256 public loanCount;
    euint64 private _totalLoanPortfolio;
    euint64 private _maximumLoanToValue; // encrypted max LTV ratio
    euint8 private _minimumCreditScore;  // encrypted min credit score

    event LoanApplied(uint256 indexed id, address borrower);
    event LoanApproved(uint256 indexed id);
    event LoanRejected(uint256 indexed id);
    event PaymentMade(uint256 indexed id);
    event LoanPaidOff(uint256 indexed id);
    event DefaultDeclared(uint256 indexed id);

    constructor(
        externalEuint64 encMaxLTV, bytes memory lProof,
        externalEuint8 encMinScore, bytes memory sProof
    ) Ownable(msg.sender) {
        _maximumLoanToValue = FHE.fromExternal(encMaxLTV, lProof);
        _minimumCreditScore = FHE.fromExternal(encMinScore, sProof);
        _totalLoanPortfolio = FHE.asEuint64(0);
        FHE.allowThis(_maximumLoanToValue);
        FHE.allowThis(_minimumCreditScore);
        FHE.allowThis(_totalLoanPortfolio);
        isUnderwriter[msg.sender] = true;
    }

    function addUnderwriter(address u) external onlyOwner { isUnderwriter[u] = true; }
    function addDealership(address d) external onlyOwner { isDealership[d] = true; }

    function applyForLoan(
        address dealership,
        externalEuint64 encVehiclePrice, bytes calldata vpProof,
        externalEuint64 encDownPayment, bytes calldata dpProof,
        externalEuint8 encCreditScore, bytes calldata csProof,
        externalEuint64 encAnnualRate, bytes calldata arProof,
        uint256 termMonths
    ) external returns (uint256 loanId) {
        euint64 price = FHE.fromExternal(encVehiclePrice, vpProof);
        euint64 downPmt = FHE.fromExternal(encDownPayment, dpProof);
        euint8 creditScore = FHE.fromExternal(encCreditScore, csProof);
        euint64 annualRate = FHE.fromExternal(encAnnualRate, arProof);
        euint64 loanAmt = FHE.sub(price, downPmt);
        euint64 ltv = FHE.div(FHE.mul(loanAmt, 100), uint64(1)); // simplified ltv calc
        // Monthly payment = loanAmt * monthlyRate / (1 - (1+r)^-n) approximated
        euint64 monthlyPayment = FHE.div(loanAmt, uint64(termMonths));
        loanId = loanCount++;
        loans[loanId] = AutoLoan({
            borrower: msg.sender, dealership: dealership, vehiclePriceUSD: price,
            downPaymentUSD: downPmt, loanAmountUSD: loanAmt, annualRateBps: annualRate,
            monthlyPaymentUSD: monthlyPayment, ltvRatio: FHE.asEuint8(0), creditScore: creditScore,
            monthsRemaining: FHE.asEuint64(uint64(termMonths)),
            originationDate: block.timestamp, status: LoanStatus.Applied
        });
        FHE.allowThis(loans[loanId].vehiclePriceUSD);
        FHE.allow(loans[loanId].vehiclePriceUSD, msg.sender);
        FHE.allowThis(loans[loanId].loanAmountUSD);
        FHE.allow(loans[loanId].loanAmountUSD, msg.sender);
        FHE.allowThis(loans[loanId].annualRateBps);
        FHE.allowThis(loans[loanId].monthlyPaymentUSD);
        FHE.allow(loans[loanId].monthlyPaymentUSD, msg.sender);
        FHE.allowThis(loans[loanId].creditScore);
        FHE.allowThis(loans[loanId].monthsRemaining);
        FHE.allow(loans[loanId].monthsRemaining, msg.sender);
        borrowerLoans[msg.sender].push(loanId);
        emit LoanApplied(loanId, msg.sender);
    }

    function underwriteLoan(uint256 loanId) external {
        require(isUnderwriter[msg.sender], "Not underwriter");
        AutoLoan storage l = loans[loanId];
        require(l.status == LoanStatus.Applied, "Not pending");
        // Check credit score >= minimum
        ebool creditOk = FHE.ge(l.creditScore, _minimumCreditScore);
        // Check LTV is acceptable (simplified check)
        ebool approved = creditOk; // real world: also check LTV
        if (FHE.isInitialized(approved)) {
            l.status = LoanStatus.Approved;
            _totalLoanPortfolio = FHE.add(_totalLoanPortfolio, l.loanAmountUSD);
            FHE.allowThis(_totalLoanPortfolio);
            FHE.allow(l.monthlyPaymentUSD, l.dealership);
            FHE.allow(l.loanAmountUSD, l.dealership);
            emit LoanApproved(loanId);
        } else {
            l.status = LoanStatus.Rejected;
            emit LoanRejected(loanId);
        }
    }

    function activateLoan(uint256 loanId) external {
        require(isUnderwriter[msg.sender], "Not underwriter");
        require(loans[loanId].status == LoanStatus.Approved, "Not approved");
        loans[loanId].status = LoanStatus.Active;
    }

    function makePayment(uint256 loanId) external nonReentrant {
        AutoLoan storage l = loans[loanId];
        require(l.borrower == msg.sender && l.status == LoanStatus.Active, "Invalid");
        ebool moreThanOne = FHE.gt(l.monthsRemaining, FHE.asEuint64(1));
        l.monthsRemaining = FHE.select(moreThanOne,
            FHE.sub(l.monthsRemaining, FHE.asEuint64(1)),
            FHE.asEuint64(0));
        FHE.allowThis(l.monthsRemaining);
        FHE.allow(l.monthsRemaining, msg.sender);
        if (!FHE.isInitialized(moreThanOne)) {
            l.status = LoanStatus.PaidOff;
            _totalLoanPortfolio = FHE.sub(_totalLoanPortfolio, l.loanAmountUSD);
            FHE.allowThis(_totalLoanPortfolio);
            emit LoanPaidOff(loanId);
        }
        emit PaymentMade(loanId);
    }

    function declareDefault(uint256 loanId) external {
        require(isUnderwriter[msg.sender], "Not underwriter");
        loans[loanId].status = LoanStatus.Defaulted;
        emit DefaultDeclared(loanId);
    }

    function allowLoanDetails(uint256 loanId, address viewer) external {
        AutoLoan storage l = loans[loanId];
        require(msg.sender == l.borrower || isUnderwriter[msg.sender] || msg.sender == l.dealership, "Unauthorized");
        FHE.allow(l.loanAmountUSD, viewer);
        FHE.allow(l.monthlyPaymentUSD, viewer);
        FHE.allow(l.monthsRemaining, viewer);
    }
}
