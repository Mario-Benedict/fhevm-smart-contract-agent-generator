// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateMicrofinanceLoanOrigination
/// @notice Microfinance institution loan book: encrypted borrower incomes,
///         encrypted group guarantee amounts, and confidential PAR ratios.
contract PrivateMicrofinanceLoanOrigination is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum LoanProduct { IndividualMicroloan, GroupSolidarity, SMELoan, AgriMicroloan, EducationMicro }
    enum RepaymentFrequency { Weekly, BiWeekly, Monthly, Quarterly }
    enum LoanStatus { Active, Delinquent, Default, Repaid, WrittenOff }

    struct BorrowerProfile {
        address borrower;
        string nationalId;
        euint32 monthlyIncomeUSD;        // encrypted monthly income
        euint32 householdSizeMembers;    // encrypted household size
        euint32 creditScore;             // encrypted internal credit score
        euint64 totalBorrowedUSD;        // encrypted lifetime borrowing
        euint64 totalRepaidUSD;          // encrypted lifetime repayments
        bool active;
    }

    struct MicroLoan {
        address borrower;
        LoanProduct product;
        RepaymentFrequency frequency;
        euint64 principalUSD;            // encrypted loan amount
        euint32 interestRateBps;         // encrypted interest rate
        euint64 outstandingBalanceUSD;   // encrypted outstanding balance
        euint64 guaranteeAmountUSD;      // encrypted group guarantee
        euint32 parRatioBps;             // encrypted PAR 30/60/90
        uint256 disbursementDate;
        uint256 maturityDate;
        LoanStatus status;
    }

    struct RepaymentRecord {
        uint256 loanId;
        euint64 amountPaidUSD;           // encrypted repayment
        euint64 principalPortion;        // encrypted principal
        euint64 interestPortion;         // encrypted interest
        uint256 paidAt;
        bool late;
    }

    mapping(address => BorrowerProfile) private profiles;
    mapping(uint256 => MicroLoan) private loans;
    mapping(uint256 => RepaymentRecord[]) private repayments;
    mapping(address => bool) public isLoanOfficer;
    mapping(address => bool) public isMFIAuditor;

    uint256 public loanCount;
    euint64 private _totalDisbursedUSD;
    euint64 private _totalOutstandingUSD;
    euint64 private _totalRepaidUSD;

    event BorrowerOnboarded(address indexed borrower);
    event LoanDisbursed(uint256 indexed id, address borrower, LoanProduct product);
    event RepaymentMade(uint256 indexed loanId, uint256 repaymentIndex);
    event LoanWrittenOff(uint256 indexed id);

    modifier onlyLoanOfficer() {
        require(isLoanOfficer[msg.sender] || msg.sender == owner(), "Not loan officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDisbursedUSD = FHE.asEuint64(0);
        _totalOutstandingUSD = FHE.asEuint64(0);
        _totalRepaidUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalDisbursedUSD);
        FHE.allowThis(_totalOutstandingUSD);
        FHE.allowThis(_totalRepaidUSD);
        isLoanOfficer[msg.sender] = true;
        isMFIAuditor[msg.sender] = true;
    }

    function addLoanOfficer(address o) external onlyOwner { isLoanOfficer[o] = true; }
    function addAuditor(address a) external onlyOwner { isMFIAuditor[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function onboardBorrower(
        address borrower, string calldata nationalId,
        externalEuint32 encIncome, bytes calldata iProof,
        externalEuint32 encHousehold, bytes calldata hProof,
        externalEuint32 encScore, bytes calldata sProof
    ) external onlyLoanOfficer whenNotPaused {
        euint32 income = FHE.fromExternal(encIncome, iProof);
        euint32 household = FHE.fromExternal(encHousehold, hProof);
        euint32 score = FHE.fromExternal(encScore, sProof);
        profiles[borrower] = BorrowerProfile({
            borrower: borrower, nationalId: nationalId,
            monthlyIncomeUSD: income, householdSizeMembers: household, creditScore: score,
            totalBorrowedUSD: FHE.asEuint64(0), totalRepaidUSD: FHE.asEuint64(0), active: true
        });
        FHE.allowThis(profiles[borrower].monthlyIncomeUSD); FHE.allow(profiles[borrower].monthlyIncomeUSD, borrower);
        FHE.allowThis(profiles[borrower].householdSizeMembers);
        FHE.allowThis(profiles[borrower].creditScore);
        FHE.allowThis(profiles[borrower].totalBorrowedUSD); FHE.allow(profiles[borrower].totalBorrowedUSD, borrower);
        FHE.allowThis(profiles[borrower].totalRepaidUSD); FHE.allow(profiles[borrower].totalRepaidUSD, borrower);
        emit BorrowerOnboarded(borrower);
    }

    function disburseLoan(
        address borrower, LoanProduct product, RepaymentFrequency frequency,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint32 encRate, bytes calldata rProof,
        externalEuint64 encGuarantee, bytes calldata gProof,
        uint256 maturityDays
    ) external onlyLoanOfficer nonReentrant whenNotPaused returns (uint256 id) {
        require(profiles[borrower].active, "Borrower not active");
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint32 rate = FHE.fromExternal(encRate, rProof);
        euint64 guarantee = FHE.fromExternal(encGuarantee, gProof);
        id = loanCount++;
        loans[id] = MicroLoan({
            borrower: borrower, product: product, frequency: frequency,
            principalUSD: principal, interestRateBps: rate,
            outstandingBalanceUSD: principal, guaranteeAmountUSD: guarantee,
            parRatioBps: FHE.asEuint32(0),
            disbursementDate: block.timestamp,
            maturityDate: block.timestamp + maturityDays * 1 days,
            status: LoanStatus.Active
        });
        profiles[borrower].totalBorrowedUSD = FHE.add(profiles[borrower].totalBorrowedUSD, principal);
        _totalDisbursedUSD = FHE.add(_totalDisbursedUSD, principal);
        _totalOutstandingUSD = FHE.add(_totalOutstandingUSD, principal);
        FHE.allowThis(loans[id].principalUSD); FHE.allow(loans[id].principalUSD, borrower);
        FHE.allowThis(loans[id].interestRateBps); FHE.allow(loans[id].interestRateBps, borrower);
        FHE.allowThis(loans[id].outstandingBalanceUSD); FHE.allow(loans[id].outstandingBalanceUSD, borrower);
        FHE.allowThis(loans[id].guaranteeAmountUSD); FHE.allow(loans[id].guaranteeAmountUSD, borrower);
        FHE.allowThis(loans[id].parRatioBps);
        FHE.allowThis(profiles[borrower].totalBorrowedUSD);
        FHE.allowThis(_totalDisbursedUSD); FHE.allowThis(_totalOutstandingUSD);
        emit LoanDisbursed(id, borrower, product);
    }

    function recordRepayment(
        uint256 loanId,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encInterest, bytes calldata iProof,
        bool late
    ) external onlyLoanOfficer nonReentrant {
        MicroLoan storage l = loans[loanId];
        require(l.status == LoanStatus.Active, "Not active");
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 interest = FHE.fromExternal(encInterest, iProof);
        l.outstandingBalanceUSD = FHE.sub(l.outstandingBalanceUSD, principal);
        _totalOutstandingUSD = FHE.sub(_totalOutstandingUSD, principal);
        _totalRepaidUSD = FHE.add(_totalRepaidUSD, amount);
        profiles[l.borrower].totalRepaidUSD = FHE.add(profiles[l.borrower].totalRepaidUSD, amount);
        repayments[loanId].push(RepaymentRecord({
            loanId: loanId, amountPaidUSD: amount, principalPortion: principal,
            interestPortion: interest, paidAt: block.timestamp, late: late
        }));
        // Check if fully repaid
        ebool fullRepay = FHE.eq(l.outstandingBalanceUSD, FHE.asEuint64(0));
        if (FHE.isInitialized(fullRepay)) l.status = LoanStatus.Repaid;
        FHE.allowThis(l.outstandingBalanceUSD); FHE.allow(l.outstandingBalanceUSD, l.borrower);
        FHE.allowThis(_totalOutstandingUSD); FHE.allowThis(_totalRepaidUSD);
        FHE.allowThis(profiles[l.borrower].totalRepaidUSD);
        emit RepaymentMade(loanId, repayments[loanId].length - 1);
    }

    function writeOffLoan(uint256 loanId) external onlyLoanOfficer {
        loans[loanId].status = LoanStatus.WrittenOff;
        _totalOutstandingUSD = FHE.sub(_totalOutstandingUSD, loans[loanId].outstandingBalanceUSD);
        FHE.allowThis(_totalOutstandingUSD);
        emit LoanWrittenOff(loanId);
    }

    function allowPortfolioStats(address viewer) external onlyOwner {
        FHE.allow(_totalDisbursedUSD, viewer);
        FHE.allow(_totalOutstandingUSD, viewer);
        FHE.allow(_totalRepaidUSD, viewer);
    }
}
