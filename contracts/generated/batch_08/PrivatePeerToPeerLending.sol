// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivatePeerToPeerLending
/// @notice P2P lending marketplace: borrowers post encrypted loan requests, lenders fund
///         with encrypted rates, repayments distributed with encrypted interest splits.
contract PrivatePeerToPeerLending is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum LoanState { Listed, Funded, Active, Repaid, Defaulted }

    struct LoanRequest {
        address borrower;
        euint64 requestedAmount;     // encrypted desired loan amount
        euint64 maxInterestRateBps;  // encrypted max rate borrower accepts
        euint64 fundedAmount;        // encrypted amount funded so far
        euint64 fundedRateBps;       // encrypted agreed rate (from lender)
        euint64 repaidAmount;        // encrypted total repaid
        uint256 termMonths;
        uint256 listedAt;
        uint256 fundedAt;
        LoanState state;
        address primaryLender;
    }

    mapping(uint256 => LoanRequest) private loanRequests;
    mapping(address => euint64) private _lenderBalance;
    mapping(address => euint64) private _lenderInterestEarned;
    mapping(address => bool) public isVerifiedBorrower;
    uint256 public requestCount;
    euint64 private _totalActiveLoans;
    euint64 private _platformFeesBps;

    event LoanRequested(uint256 indexed id, address borrower);
    event LoanFunded(uint256 indexed id, address lender);
    event RepaymentReceived(uint256 indexed id);
    event LoanDefaulted(uint256 indexed id);

    constructor(externalEuint64 encPlatformFee, bytes memory proof) Ownable(msg.sender) {
        _platformFeesBps = FHE.fromExternal(encPlatformFee, proof);
        _totalActiveLoans = FHE.asEuint64(0);
        FHE.allowThis(_platformFeesBps);
        FHE.allowThis(_totalActiveLoans);
        isVerifiedBorrower[msg.sender] = true;
    }

    function verifyBorrower(address b) external onlyOwner { isVerifiedBorrower[b] = true; }

    function requestLoan(
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint64 encMaxRate, bytes calldata rProof,
        uint256 termMonths
    ) external returns (uint256 id) {
        require(isVerifiedBorrower[msg.sender], "Not verified");
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint64 maxRate = FHE.fromExternal(encMaxRate, rProof);
        id = requestCount++;
        loanRequests[id].borrower = msg.sender;
        loanRequests[id].requestedAmount = amount;
        loanRequests[id].maxInterestRateBps = maxRate;
        loanRequests[id].fundedAmount = FHE.asEuint64(0);
        loanRequests[id].fundedRateBps = FHE.asEuint64(0);
        loanRequests[id].repaidAmount = FHE.asEuint64(0);
        loanRequests[id].termMonths = termMonths;
        loanRequests[id].listedAt = block.timestamp;
        loanRequests[id].fundedAt = 0;
        loanRequests[id].state = LoanState.Listed;
        loanRequests[id].primaryLender = address(0);
        FHE.allowThis(loanRequests[id].requestedAmount);
        FHE.allow(loanRequests[id].requestedAmount, msg.sender);
        FHE.allowThis(loanRequests[id].maxInterestRateBps);
        FHE.allow(loanRequests[id].maxInterestRateBps, msg.sender);
        FHE.allowThis(loanRequests[id].fundedAmount);
        FHE.allowThis(loanRequests[id].fundedRateBps);
        FHE.allowThis(loanRequests[id].repaidAmount);
        emit LoanRequested(id, msg.sender);
    }

    function fundLoan(
        uint256 loanId,
        externalEuint64 encOfferedRate, bytes calldata proof
    ) external nonReentrant {
        LoanRequest storage req = loanRequests[loanId];
        require(req.state == LoanState.Listed, "Not listed");
        euint64 offeredRate = FHE.fromExternal(encOfferedRate, proof);
        // Only accept if offered rate <= borrower's max
        ebool rateOk = FHE.le(offeredRate, req.maxInterestRateBps);
        euint64 acceptedRate = FHE.select(rateOk, offeredRate, FHE.asEuint64(type(uint64).max));
        req.fundedAmount = FHE.select(rateOk, req.requestedAmount, FHE.asEuint64(0));
        req.fundedRateBps = acceptedRate;
        req.primaryLender = msg.sender;
        req.fundedAt = block.timestamp;
        req.state = FHE.isInitialized(rateOk) ? LoanState.Active : LoanState.Listed;
        _totalActiveLoans = FHE.add(_totalActiveLoans, req.fundedAmount);
        FHE.allowThis(req.fundedAmount);
        FHE.allow(req.fundedAmount, req.borrower);
        FHE.allow(req.fundedAmount, msg.sender);
        FHE.allowThis(req.fundedRateBps);
        FHE.allow(req.fundedRateBps, req.borrower);
        FHE.allow(req.fundedRateBps, msg.sender);
        FHE.allowThis(_totalActiveLoans);
        if (!FHE.isInitialized(_lenderBalance[msg.sender])) {
            _lenderBalance[msg.sender] = FHE.asEuint64(0);
            _lenderInterestEarned[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_lenderBalance[msg.sender]);
            FHE.allowThis(_lenderInterestEarned[msg.sender]);
        }
        if (FHE.isInitialized(rateOk)) emit LoanFunded(loanId, msg.sender);
    }

    function makeRepayment(uint256 loanId, externalEuint64 encPayment, bytes calldata proof) external nonReentrant {
        LoanRequest storage req = loanRequests[loanId];
        require(req.borrower == msg.sender && req.state == LoanState.Active, "Invalid");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        // Interest portion = payment * rate / (10000 * 12)
        euint64 interestPortion = FHE.div(FHE.mul(payment, req.fundedRateBps), 120000);
        euint64 principalPortion = FHE.sub(payment, interestPortion);
        // Platform fee on interest
        euint64 platFee = FHE.div(FHE.mul(interestPortion, _platformFeesBps), 10000);
        euint64 lenderInterest = FHE.sub(interestPortion, platFee);
        req.repaidAmount = FHE.add(req.repaidAmount, payment);
        _lenderBalance[req.primaryLender] = FHE.add(_lenderBalance[req.primaryLender], principalPortion);
        _lenderInterestEarned[req.primaryLender] = FHE.add(_lenderInterestEarned[req.primaryLender], lenderInterest);
        FHE.allowThis(req.repaidAmount);
        FHE.allow(req.repaidAmount, msg.sender);
        FHE.allowThis(_lenderBalance[req.primaryLender]);
        FHE.allow(_lenderBalance[req.primaryLender], req.primaryLender);
        FHE.allowThis(_lenderInterestEarned[req.primaryLender]);
        FHE.allow(_lenderInterestEarned[req.primaryLender], req.primaryLender);
        // Check if fully repaid
        ebool done = FHE.ge(req.repaidAmount, req.fundedAmount);
        if (FHE.isInitialized(done)) {
            req.state = LoanState.Repaid;
            _totalActiveLoans = FHE.sub(_totalActiveLoans, req.fundedAmount);
            FHE.allowThis(_totalActiveLoans);
        }
        emit RepaymentReceived(loanId);
    }

    function declareDefault(uint256 loanId) external onlyOwner {
        loanRequests[loanId].state = LoanState.Defaulted;
        _totalActiveLoans = FHE.sub(_totalActiveLoans, loanRequests[loanId].fundedAmount);
        FHE.allowThis(_totalActiveLoans);
        emit LoanDefaulted(loanId);
    }

    function allowLoanDetails(uint256 loanId, address viewer) external {
        LoanRequest storage r = loanRequests[loanId];
        require(msg.sender == r.borrower || msg.sender == r.primaryLender || msg.sender == owner(), "Unauthorized");
        FHE.allow(r.requestedAmount, viewer);
        FHE.allow(r.fundedRateBps, viewer);
        FHE.allow(r.repaidAmount, viewer);
    }
}
