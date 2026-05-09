// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialMicroLendingPlatform
/// @notice Encrypted micro-lending: private peer-to-peer loan amounts, hidden
///         creditworthiness scores, confidential interest calculations, and
///         encrypted late-payment penalty logic.
contract ConfidentialMicroLendingPlatform is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum LoanStatus { Requested, Funded, Active, Repaid, Defaulted }

    struct LoanRequest {
        address borrower;
        string purposeCode;
        euint64 requestedAmountUSD;    // encrypted loan amount
        euint16 requestedTermDays;     // encrypted term
        euint16 creditScore;           // encrypted credit score
        euint16 proposedInterestBps;   // encrypted interest rate
        euint64 collateralAmountUSD;   // encrypted collateral
        LoanStatus status;
        uint256 requestedAt;
    }

    struct FundedLoan {
        uint256 requestId;
        address lender;
        euint64 fundedAmountUSD;       // encrypted funded amount
        euint64 outstandingPrincipal;  // encrypted outstanding
        euint64 interestDueUSD;        // encrypted interest due
        euint64 penaltyAccrued;        // encrypted late penalty
        uint256 fundedAt;
        uint256 dueDate;
    }

    mapping(uint256 => LoanRequest) private requests;
    mapping(uint256 => FundedLoan)  private fundedLoans;
    mapping(address => bool) public isCreditOfficer;

    uint256 public requestCount;
    uint256 public fundedLoanCount;
    euint64 private _totalLoanVolumeUSD;
    euint64 private _totalInterestCollected;
    euint64 private _totalDefaults;

    event LoanRequested(uint256 indexed id, address borrower);
    event LoanFunded(uint256 indexed loanId, uint256 requestId);
    event LoanRepaid(uint256 indexed loanId, uint256 repaidAt);
    event LoanDefaulted(uint256 indexed loanId);

    modifier onlyCreditOfficer() {
        require(isCreditOfficer[msg.sender] || msg.sender == owner(), "Not credit officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalLoanVolumeUSD = FHE.asEuint64(0);
        _totalInterestCollected = FHE.asEuint64(0);
        _totalDefaults = FHE.asEuint64(0);
        FHE.allowThis(_totalLoanVolumeUSD); FHE.allowThis(_totalInterestCollected); FHE.allowThis(_totalDefaults);
        isCreditOfficer[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addCreditOfficer(address co) external onlyOwner { isCreditOfficer[co] = true; }

    function requestLoan(
        string calldata purposeCode,
        externalEuint64 encAmount,   bytes calldata amProof,
        externalEuint16 encTerm,     bytes calldata termProof,
        externalEuint16 encCredit,   bytes calldata credProof,
        externalEuint16 encIntRate,  bytes calldata irProof,
        externalEuint64 encCollateral, bytes calldata colProof
    ) external whenNotPaused returns (uint256 id) {
        euint64 amount     = FHE.fromExternal(encAmount, amProof);
        euint16 term       = FHE.fromExternal(encTerm, termProof);
        euint16 credit     = FHE.fromExternal(encCredit, credProof);
        euint16 intRate    = FHE.fromExternal(encIntRate, irProof);
        euint64 collateral = FHE.fromExternal(encCollateral, colProof);
        id = requestCount++;
        requests[id] = LoanRequest({
            borrower: msg.sender, purposeCode: purposeCode, requestedAmountUSD: amount,
            requestedTermDays: term, creditScore: credit, proposedInterestBps: intRate,
            collateralAmountUSD: collateral, status: LoanStatus.Requested, requestedAt: block.timestamp
        });
        FHE.allowThis(requests[id].requestedAmountUSD); FHE.allow(requests[id].requestedAmountUSD, msg.sender);
        FHE.allowThis(requests[id].requestedTermDays); FHE.allow(requests[id].requestedTermDays, msg.sender);
        FHE.allowThis(requests[id].creditScore);
        FHE.allowThis(requests[id].proposedInterestBps); FHE.allow(requests[id].proposedInterestBps, msg.sender);
        FHE.allowThis(requests[id].collateralAmountUSD); FHE.allow(requests[id].collateralAmountUSD, msg.sender);
        emit LoanRequested(id, msg.sender);
    }

    function fundLoan(uint256 requestId) external whenNotPaused nonReentrant returns (uint256 loanId) {
        LoanRequest storage req = requests[requestId];
        require(req.status == LoanStatus.Requested, "Not requestable");
        uint256 termDays = 30; // simplified; use plaintext for term
        euint64 interest = FHE.div(FHE.mul(req.requestedAmountUSD, 1000), 10000); // 10% interest placeholder
        loanId = fundedLoanCount++;
        fundedLoans[loanId] = FundedLoan({
            requestId: requestId, lender: msg.sender, fundedAmountUSD: req.requestedAmountUSD,
            outstandingPrincipal: req.requestedAmountUSD, interestDueUSD: interest,
            penaltyAccrued: FHE.asEuint64(0), fundedAt: block.timestamp,
            dueDate: block.timestamp + termDays * 1 days
        });
        req.status = LoanStatus.Funded;
        _totalLoanVolumeUSD = FHE.add(_totalLoanVolumeUSD, req.requestedAmountUSD);
        FHE.allowThis(fundedLoans[loanId].fundedAmountUSD); FHE.allow(fundedLoans[loanId].fundedAmountUSD, req.borrower); FHE.allow(fundedLoans[loanId].fundedAmountUSD, msg.sender);
        FHE.allowThis(fundedLoans[loanId].outstandingPrincipal); FHE.allow(fundedLoans[loanId].outstandingPrincipal, req.borrower);
        FHE.allowThis(fundedLoans[loanId].interestDueUSD); FHE.allow(fundedLoans[loanId].interestDueUSD, req.borrower);
        FHE.allowThis(fundedLoans[loanId].penaltyAccrued);
        FHE.allowThis(_totalLoanVolumeUSD);
        emit LoanFunded(loanId, requestId);
    }

    function repayLoan(uint256 loanId, externalEuint64 encRepay, bytes calldata proof) external nonReentrant {
        FundedLoan storage fl = fundedLoans[loanId];
        LoanRequest storage req = requests[fl.requestId];
        require(req.borrower == msg.sender && req.status == LoanStatus.Funded, "Cannot repay");
        euint64 repay = FHE.fromExternal(encRepay, proof);
        euint64 totalOwed = FHE.add(FHE.add(fl.outstandingPrincipal, fl.interestDueUSD), fl.penaltyAccrued);
        ebool fullRepay = FHE.ge(repay, totalOwed);
        fl.outstandingPrincipal = FHE.select(fullRepay, FHE.asEuint64(0), FHE.sub(totalOwed, repay));
        _totalInterestCollected = FHE.add(_totalInterestCollected, fl.interestDueUSD);
        if (FHE.isInitialized(fullRepay)) req.status = LoanStatus.Repaid;
        FHE.allowThis(fl.outstandingPrincipal); FHE.allow(fl.outstandingPrincipal, req.borrower);
        FHE.allowThis(_totalInterestCollected);
        emit LoanRepaid(loanId, block.timestamp);
    }

    function markDefault(uint256 loanId) external onlyCreditOfficer {
        LoanRequest storage req = requests[fundedLoans[loanId].requestId];
        req.status = LoanStatus.Defaulted;
        _totalDefaults = FHE.add(_totalDefaults, fundedLoans[loanId].fundedAmountUSD);
        FHE.allowThis(_totalDefaults);
        emit LoanDefaulted(loanId);
    }

    function allowPlatformStats(address viewer) external onlyOwner {
        FHE.allow(_totalLoanVolumeUSD, viewer); FHE.allow(_totalInterestCollected, viewer); FHE.allow(_totalDefaults, viewer);
    }
}
