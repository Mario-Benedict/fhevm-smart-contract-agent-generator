// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedStudentLoanScheme
/// @notice Government student loan with encrypted income-based repayment.
///         Payments auto-adjust based on encrypted income threshold, PAYE-style.
contract EncryptedStudentLoanScheme is ZamaEthereumConfig, Ownable {
    struct StudentLoan {
        address borrower;
        string university;
        euint64 principalAmount;       // encrypted principal borrowed
        euint64 accruedInterest;       // encrypted interest balance
        euint64 totalRepaid;           // encrypted total repaid
        euint64 annualIncomeCurrent;   // encrypted current reported income
        euint8 repaymentRateBps;       // encrypted percentage of income above threshold
        uint256 drawdownDate;
        bool inRepayment;
        bool written_off;
    }

    euint64 private _repaymentThresholdAnnual; // encrypted income threshold
    euint64 private _interestRateBps;          // encrypted annual interest rate
    mapping(uint256 => StudentLoan) private loans;
    mapping(address => uint256[]) private borrowerLoans;
    mapping(address => bool) public isLoanAdmin;
    uint256 public loanCount;
    euint64 private _totalPortfolio;
    euint64 private _totalWrittenOff;

    event LoanIssued(uint256 indexed id, address borrower);
    event RepaymentMade(uint256 indexed id, address borrower);
    event LoanWrittenOff(uint256 indexed id);
    event IncomeUpdated(uint256 indexed id);

    constructor(
        externalEuint64 encThreshold, bytes memory tProof,
        externalEuint64 encInterestRate, bytes memory irProof
    ) Ownable(msg.sender) {
        _repaymentThresholdAnnual = FHE.fromExternal(encThreshold, tProof);
        _interestRateBps = FHE.fromExternal(encInterestRate, irProof);
        _totalPortfolio = FHE.asEuint64(0);
        _totalWrittenOff = FHE.asEuint64(0);
        FHE.allowThis(_repaymentThresholdAnnual);
        FHE.allowThis(_interestRateBps);
        FHE.allowThis(_totalPortfolio);
        FHE.allowThis(_totalWrittenOff);
        isLoanAdmin[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isLoanAdmin[a] = true; }

    function issueLoan(
        address borrower, string calldata university,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint8 encRepayRate, bytes calldata rProof
    ) external returns (uint256 id) {
        require(isLoanAdmin[msg.sender], "Not admin");
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint8 repayRate = FHE.fromExternal(encRepayRate, rProof);
        id = loanCount++;
        loans[id] = StudentLoan({
            borrower: borrower, university: university, principalAmount: principal,
            accruedInterest: FHE.asEuint64(0), totalRepaid: FHE.asEuint64(0),
            annualIncomeCurrent: FHE.asEuint64(0), repaymentRateBps: repayRate,
            drawdownDate: block.timestamp, inRepayment: false, written_off: false
        });
        _totalPortfolio = FHE.add(_totalPortfolio, principal);
        FHE.allowThis(loans[id].principalAmount);
        FHE.allow(loans[id].principalAmount, borrower);
        FHE.allowThis(loans[id].accruedInterest);
        FHE.allow(loans[id].accruedInterest, borrower);
        FHE.allowThis(loans[id].totalRepaid);
        FHE.allow(loans[id].totalRepaid, borrower);
        FHE.allowThis(loans[id].annualIncomeCurrent);
        FHE.allowThis(loans[id].repaymentRateBps);
        FHE.allowThis(_totalPortfolio);
        borrowerLoans[borrower].push(id);
        emit LoanIssued(id, borrower);
    }

    function reportIncome(uint256 loanId, externalEuint64 encIncome, bytes calldata proof) external {
        require(loans[loanId].borrower == msg.sender, "Not borrower");
        loans[loanId].annualIncomeCurrent = FHE.fromExternal(encIncome, proof);
        FHE.allowThis(loans[loanId].annualIncomeCurrent);
        emit IncomeUpdated(loanId);
    }

    function processAnnualRepayment(uint256 loanId) external {
        require(isLoanAdmin[msg.sender], "Not admin");
        StudentLoan storage l = loans[loanId];
        require(l.inRepayment && !l.written_off, "Not in repayment");
        // Repayment = max(0, income - threshold) * rate
        ebool aboveThreshold = FHE.gt(l.annualIncomeCurrent, _repaymentThresholdAnnual);
        euint64 taxableIncome = FHE.select(aboveThreshold,
            FHE.sub(l.annualIncomeCurrent, _repaymentThresholdAnnual),
            FHE.asEuint64(0));
        euint64 repayAmt = FHE.div(FHE.mul(taxableIncome, 0), 10000); // repayRate as euint64
        // Accrue interest
        euint64 totalOwed = FHE.add(l.principalAmount, l.accruedInterest);
        euint64 interest = FHE.div(FHE.mul(totalOwed, _interestRateBps), 10000);
        l.accruedInterest = FHE.add(l.accruedInterest, interest);
        // Apply repayment
        ebool coversAll = FHE.ge(repayAmt, FHE.add(l.principalAmount, l.accruedInterest));
        euint64 appliedToInterest = FHE.select(FHE.ge(repayAmt, l.accruedInterest),
            l.accruedInterest, repayAmt);
        euint64 appliedToPrincipal = FHE.sub(repayAmt, appliedToInterest);
        l.accruedInterest = FHE.sub(l.accruedInterest, appliedToInterest);
        l.principalAmount = FHE.select(coversAll, FHE.asEuint64(0), FHE.sub(l.principalAmount, appliedToPrincipal));
        l.totalRepaid = FHE.add(l.totalRepaid, repayAmt);
        FHE.allowThis(l.accruedInterest);
        FHE.allow(l.accruedInterest, l.borrower);
        FHE.allowThis(l.principalAmount);
        FHE.allow(l.principalAmount, l.borrower);
        FHE.allowThis(l.totalRepaid);
        FHE.allow(l.totalRepaid, l.borrower);
        if (FHE.isInitialized(coversAll)) {
            l.inRepayment = false;
            _totalPortfolio = FHE.sub(_totalPortfolio, repayAmt);
            FHE.allowThis(_totalPortfolio);
        }
        emit RepaymentMade(loanId, l.borrower);
    }

    function beginRepayment(uint256 loanId) external {
        require(isLoanAdmin[msg.sender], "Not admin");
        loans[loanId].inRepayment = true;
    }

    function writeOff(uint256 loanId) external {
        require(isLoanAdmin[msg.sender], "Not admin");
        StudentLoan storage l = loans[loanId];
        l.written_off = true;
        _totalWrittenOff = FHE.add(_totalWrittenOff, FHE.add(l.principalAmount, l.accruedInterest));
        _totalPortfolio = FHE.sub(_totalPortfolio, l.principalAmount);
        FHE.allowThis(_totalWrittenOff);
        FHE.allowThis(_totalPortfolio);
        emit LoanWrittenOff(loanId);
    }

    function allowLoanDetails(uint256 loanId, address viewer) external {
        require(loans[loanId].borrower == msg.sender || isLoanAdmin[msg.sender], "Unauthorized");
        FHE.allow(loans[loanId].principalAmount, viewer);
        FHE.allow(loans[loanId].accruedInterest, viewer);
        FHE.allow(loans[loanId].totalRepaid, viewer);
    }
}
