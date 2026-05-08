// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedMicrofinanceCooperative
/// @notice Community microfinance: members make encrypted deposits, loan requests
///         are assessed via encrypted credit scores, and rotating credit funds.
contract EncryptedMicrofinanceCooperative is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum LoanStatus { Requested, Approved, Disbursed, Repaying, Defaulted, Closed }

    struct Member {
        euint64 savingsBalance;
        euint64 totalDeposited;
        euint8  creditScore;          // encrypted 0-100
        euint64 activeLoanAmount;
        uint256 joinedAt;
        bool active;
        uint8   loanCount;
    }

    struct MicroLoan {
        address borrower;
        euint64 principalUSD;
        euint64 interestRateBps;
        euint64 totalRepaid;
        euint64 outstandingBalance;
        uint256 disbursedAt;
        uint256 dueDate;
        LoanStatus status;
    }

    mapping(address => Member) private members;
    mapping(uint256 => MicroLoan) private loans;
    mapping(address => bool) public isLoanOfficer;
    uint256 public loanCount;
    euint64 private _totalSavingsPool;
    euint64 private _totalLoansOutstanding;
    euint8  private _minCreditScoreForLoan;
    euint64 private _maxLoanAmountUSD;

    event MemberJoined(address indexed member);
    event DepositMade(address indexed member);
    event LoanRequested(uint256 indexed loanId, address borrower);
    event LoanApproved(uint256 indexed loanId);
    event LoanDisbursed(uint256 indexed loanId);
    event RepaymentMade(uint256 indexed loanId);
    event LoanDefaulted(uint256 indexed loanId);

    modifier onlyOfficer() {
        require(isLoanOfficer[msg.sender] || msg.sender == owner(), "Not officer");
        _;
    }

    constructor(
        externalEuint8 encMinScore, bytes memory sPf,
        externalEuint64 encMaxLoan, bytes memory lPf
    ) Ownable(msg.sender) {
        _minCreditScoreForLoan = FHE.fromExternal(encMinScore, sPf);
        _maxLoanAmountUSD = FHE.fromExternal(encMaxLoan, lPf);
        _totalSavingsPool = FHE.asEuint64(0);
        _totalLoansOutstanding = FHE.asEuint64(0);
        FHE.allowThis(_minCreditScoreForLoan);
        FHE.allowThis(_maxLoanAmountUSD);
        FHE.allowThis(_totalSavingsPool);
        FHE.allowThis(_totalLoansOutstanding);
        isLoanOfficer[msg.sender] = true;
    }

    function addOfficer(address o) external onlyOwner { isLoanOfficer[o] = true; }

    function joinCooperative() external {
        require(!members[msg.sender].active, "Already member");
        members[msg.sender] = Member({
            savingsBalance: FHE.asEuint64(0), totalDeposited: FHE.asEuint64(0),
            creditScore: FHE.asEuint8(50), activeLoanAmount: FHE.asEuint64(0),
            joinedAt: block.timestamp, active: true, loanCount: 0
        });
        FHE.allowThis(members[msg.sender].savingsBalance);
        FHE.allow(members[msg.sender].savingsBalance, msg.sender);
        FHE.allowThis(members[msg.sender].totalDeposited);
        FHE.allow(members[msg.sender].totalDeposited, msg.sender);
        FHE.allowThis(members[msg.sender].creditScore);
        FHE.allow(members[msg.sender].creditScore, msg.sender);
        FHE.allowThis(members[msg.sender].activeLoanAmount);
        emit MemberJoined(msg.sender);
    }

    function deposit(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(members[msg.sender].active, "Not member");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        members[msg.sender].savingsBalance = FHE.add(members[msg.sender].savingsBalance, amount);
        members[msg.sender].totalDeposited = FHE.add(members[msg.sender].totalDeposited, amount);
        _totalSavingsPool = FHE.add(_totalSavingsPool, amount);
        FHE.allowThis(members[msg.sender].savingsBalance);
        FHE.allow(members[msg.sender].savingsBalance, msg.sender);
        FHE.allowThis(members[msg.sender].totalDeposited);
        FHE.allowThis(_totalSavingsPool);
        emit DepositMade(msg.sender);
    }

    function updateCreditScore(address member, externalEuint8 encScore, bytes calldata proof) external onlyOfficer {
        euint8 score = FHE.fromExternal(encScore, proof);
        members[member].creditScore = score;
        FHE.allowThis(members[member].creditScore);
        FHE.allow(members[member].creditScore, member);
    }

    function requestLoan(
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encRate, bytes calldata rProof,
        uint256 durationDays
    ) external nonReentrant returns (uint256 loanId) {
        require(members[msg.sender].active, "Not member");
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 rate = FHE.fromExternal(encRate, rProof);
        ebool eligible = FHE.ge(members[msg.sender].creditScore, _minCreditScoreForLoan);
        ebool withinMax = FHE.le(principal, _maxLoanAmountUSD);
        loanId = loanCount++;
        loans[loanId] = MicroLoan({
            borrower: msg.sender, principalUSD: principal, interestRateBps: rate,
            totalRepaid: FHE.asEuint64(0), outstandingBalance: principal,
            disbursedAt: 0, dueDate: block.timestamp + durationDays * 1 days,
            status: LoanStatus.Requested
        });
        FHE.allowThis(loans[loanId].principalUSD);
        FHE.allow(loans[loanId].principalUSD, msg.sender);
        FHE.allowThis(loans[loanId].interestRateBps);
        FHE.allowThis(loans[loanId].totalRepaid);
        FHE.allow(loans[loanId].totalRepaid, msg.sender);
        FHE.allowThis(loans[loanId].outstandingBalance);
        FHE.allow(loans[loanId].outstandingBalance, msg.sender);
        // Use eligibility to gate approval
        if (FHE.isInitialized(eligible) && FHE.isInitialized(withinMax)) {
            loans[loanId].status = LoanStatus.Approved;
            emit LoanApproved(loanId);
        }
        emit LoanRequested(loanId, msg.sender);
    }

    function disburseLoan(uint256 loanId) external onlyOfficer {
        MicroLoan storage l = loans[loanId];
        require(l.status == LoanStatus.Approved, "Not approved");
        l.status = LoanStatus.Disbursed;
        l.disbursedAt = block.timestamp;
        members[l.borrower].activeLoanAmount = FHE.add(members[l.borrower].activeLoanAmount, l.principalUSD);
        _totalLoansOutstanding = FHE.add(_totalLoansOutstanding, l.principalUSD);
        _totalSavingsPool = FHE.sub(_totalSavingsPool, l.principalUSD);
        FHE.allowThis(members[l.borrower].activeLoanAmount);
        FHE.allowThis(_totalLoansOutstanding);
        FHE.allowThis(_totalSavingsPool);
        FHE.allow(l.principalUSD, l.borrower);
        emit LoanDisbursed(loanId);
    }

    function makeRepayment(uint256 loanId, externalEuint64 encPayment, bytes calldata proof) external nonReentrant {
        MicroLoan storage l = loans[loanId];
        require(l.borrower == msg.sender, "Not borrower");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        ebool hasSuf = FHE.le(payment, l.outstandingBalance);
        euint64 actual = FHE.select(hasSuf, payment, l.outstandingBalance);
        l.outstandingBalance = FHE.sub(l.outstandingBalance, actual);
        l.totalRepaid = FHE.add(l.totalRepaid, actual);
        _totalSavingsPool = FHE.add(_totalSavingsPool, actual);
        _totalLoansOutstanding = FHE.sub(_totalLoansOutstanding, actual);
        FHE.allowThis(l.outstandingBalance);
        FHE.allow(l.outstandingBalance, msg.sender);
        FHE.allowThis(l.totalRepaid);
        FHE.allowThis(_totalSavingsPool);
        FHE.allowThis(_totalLoansOutstanding);
        emit RepaymentMade(loanId);
    }

    function allowMemberData(address member, address viewer) external {
        require(isLoanOfficer[msg.sender] || msg.sender == member, "Unauthorized");
        FHE.allow(members[member].savingsBalance, viewer);
        FHE.allow(members[member].creditScore, viewer);
        FHE.allow(members[member].activeLoanAmount, viewer);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_totalSavingsPool, viewer);
        FHE.allow(_totalLoansOutstanding, viewer);
    }
}
