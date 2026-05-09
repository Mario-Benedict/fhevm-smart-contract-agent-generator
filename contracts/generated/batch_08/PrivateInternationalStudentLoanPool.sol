// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateInternationalStudentLoanPool
/// @notice Cross-border student loan securitization pool: encrypted loan amounts per student,
///         confidential repayment performance scores, hidden pool subordination structure,
///         and private tranche waterfall for senior/mezzanine/equity investors.
contract PrivateInternationalStudentLoanPool is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum LoanStatus { Active, Deferment, Default, PaidOff }
    enum Tranche { Senior, Mezzanine, Equity }

    struct StudentLoan {
        address borrower;
        string studentId;
        string institutionCode;
        euint64 principalUSD;          // encrypted loan amount
        euint64 outstandingBalanceUSD; // encrypted remaining balance
        euint16 interestRateBps;       // encrypted interest rate
        euint8  repaymentScorePoints;  // encrypted repayment behavior score
        euint32 defermentMonths;       // encrypted deferment period
        LoanStatus status;
        uint256 disbursedAt;
        uint256 maturityDate;
    }

    struct InvestorTranche {
        address investor;
        Tranche tranche;
        euint64 investedAmountUSD;     // encrypted investment
        euint64 principalReceivedUSD;  // encrypted principal returned
        euint64 interestReceivedUSD;   // encrypted interest received
        euint16 subordinationRatioBps; // encrypted loss protection level
        bool active;
    }

    mapping(uint256 => StudentLoan) private loans;
    mapping(uint256 => InvestorTranche) private tranches;
    mapping(address => bool) public isPoolManager;

    uint256 public loanCount;
    uint256 public trancheCount;
    euint64 private _totalPoolSizeUSD;
    euint64 private _totalRepaidUSD;
    euint64 private _totalDefaultedUSD;

    event LoanAdded(uint256 indexed id, string studentId, string institutionCode);
    event RepaymentProcessed(uint256 indexed loanId, uint256 processedAt);
    event TrancheInvested(uint256 indexed trancheId, Tranche tranche, address investor);

    modifier onlyPoolManager() {
        require(isPoolManager[msg.sender] || msg.sender == owner(), "Not pool manager");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPoolSizeUSD = FHE.asEuint64(0);
        _totalRepaidUSD = FHE.asEuint64(0);
        _totalDefaultedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalPoolSizeUSD);
        FHE.allowThis(_totalRepaidUSD);
        FHE.allowThis(_totalDefaultedUSD);
        isPoolManager[msg.sender] = true;
    }

    function addPoolManager(address pm) external onlyOwner { isPoolManager[pm] = true; }

    function addLoan(
        address borrower,
        string calldata studentId,
        string calldata institutionCode,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint16 encRate, bytes calldata rProof,
        externalEuint32 encDeferment, bytes calldata dProof,
        uint256 maturityDays
    ) external onlyPoolManager returns (uint256 id) {
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint16 rate = FHE.fromExternal(encRate, rProof);
        euint32 deferment = FHE.fromExternal(encDeferment, dProof);
        id = loanCount++;
        loans[id].borrower = borrower;
        loans[id].studentId = studentId;
        loans[id].institutionCode = institutionCode;
        loans[id].principalUSD = principal;
        loans[id].outstandingBalanceUSD = principal;
        loans[id].interestRateBps = rate;
        loans[id].repaymentScorePoints = FHE.asEuint8(100);
        loans[id].defermentMonths = deferment;
        loans[id].status = LoanStatus.Active;
        loans[id].disbursedAt = block.timestamp;
        loans[id].maturityDate = block.timestamp + maturityDays * 1 days;
        _totalPoolSizeUSD = FHE.add(_totalPoolSizeUSD, principal);
        FHE.allowThis(loans[id].principalUSD); FHE.allow(loans[id].principalUSD, borrower);
        FHE.allowThis(loans[id].outstandingBalanceUSD); FHE.allow(loans[id].outstandingBalanceUSD, borrower);
        FHE.allowThis(loans[id].interestRateBps); FHE.allow(loans[id].interestRateBps, borrower);
        FHE.allowThis(loans[id].repaymentScorePoints); FHE.allow(loans[id].repaymentScorePoints, borrower);
        FHE.allowThis(loans[id].defermentMonths); FHE.allow(loans[id].defermentMonths, borrower);
        FHE.allowThis(_totalPoolSizeUSD);
        emit LoanAdded(id, studentId, institutionCode);
    }

    function processRepayment(
        uint256 loanId,
        externalEuint64 encRepayAmt, bytes calldata proof
    ) external nonReentrant {
        StudentLoan storage l = loans[loanId];
        require(msg.sender == l.borrower || isPoolManager[msg.sender], "Not authorized");
        require(l.status == LoanStatus.Active, "Not active");
        euint64 repayAmt = FHE.fromExternal(encRepayAmt, proof);
        ebool fullRepay = FHE.ge(repayAmt, l.outstandingBalanceUSD);
        euint64 applied = FHE.select(fullRepay, l.outstandingBalanceUSD, repayAmt);
        l.outstandingBalanceUSD = FHE.sub(l.outstandingBalanceUSD, applied);
        _totalRepaidUSD = FHE.add(_totalRepaidUSD, applied);
        // Improve repayment score on-time payment
        euint8 newScore = FHE.add(l.repaymentScorePoints, FHE.asEuint8(1));
        l.repaymentScorePoints = newScore;
        if (FHE.isInitialized(fullRepay)) l.status = LoanStatus.PaidOff;
        FHE.allowThis(l.outstandingBalanceUSD); FHE.allow(l.outstandingBalanceUSD, l.borrower);
        FHE.allowThis(l.repaymentScorePoints); FHE.allow(l.repaymentScorePoints, l.borrower);
        FHE.allowThis(_totalRepaidUSD);
        emit RepaymentProcessed(loanId, block.timestamp);
    }

    function addTranche(
        address investor,
        Tranche tranche,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint16 encSubordination, bytes calldata sProof
    ) external onlyPoolManager returns (uint256 trancheId) {
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint16 subordination = FHE.fromExternal(encSubordination, sProof);
        trancheId = trancheCount++;
        tranches[trancheId] = InvestorTranche({
            investor: investor, tranche: tranche, investedAmountUSD: amount,
            principalReceivedUSD: FHE.asEuint64(0), interestReceivedUSD: FHE.asEuint64(0),
            subordinationRatioBps: subordination, active: true
        });
        FHE.allowThis(tranches[trancheId].investedAmountUSD); FHE.allow(tranches[trancheId].investedAmountUSD, investor);
        FHE.allowThis(tranches[trancheId].principalReceivedUSD); FHE.allow(tranches[trancheId].principalReceivedUSD, investor);
        FHE.allowThis(tranches[trancheId].interestReceivedUSD); FHE.allow(tranches[trancheId].interestReceivedUSD, investor);
        FHE.allowThis(tranches[trancheId].subordinationRatioBps);
        emit TrancheInvested(trancheId, tranche, investor);
    }

    function markDefault(uint256 loanId) external onlyPoolManager {
        StudentLoan storage l = loans[loanId];
        require(l.status == LoanStatus.Active, "Not active");
        l.status = LoanStatus.Default;
        _totalDefaultedUSD = FHE.add(_totalDefaultedUSD, l.outstandingBalanceUSD);
        FHE.allowThis(_totalDefaultedUSD);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_totalPoolSizeUSD, viewer);
        FHE.allow(_totalRepaidUSD, viewer);
        FHE.allow(_totalDefaultedUSD, viewer);
    }
}
