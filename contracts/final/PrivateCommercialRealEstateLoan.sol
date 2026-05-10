// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCommercialRealEstateLoan
/// @notice Commercial real estate CMBS-style loan with encrypted LTV ratios,
///         encrypted NOI, DSCR calculations, and confidential debt service reserve.
contract PrivateCommercialRealEstateLoan is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum PropertyType { Office, Retail, Industrial, Multifamily, Hotel, MixedUse }
    enum LoanStatus { Originated, Current, WatchList, SpecialServicing, Default, Paid }

    struct CMBSLoan {
        address borrower;
        string propertyAddress;
        PropertyType propType;
        euint64 principalBalanceUSD;   // encrypted outstanding principal
        euint64 appraisedValueUSD;     // encrypted property appraisal
        euint32 ltvRatioBps;           // encrypted LTV ratio
        euint64 annualNOI_USD;         // encrypted Net Operating Income
        euint32 dscrBps;               // encrypted Debt Service Coverage Ratio
        euint32 interestRateBps;       // encrypted interest rate
        euint64 debtServiceReserveUSD; // encrypted reserve fund
        uint256 maturityDate;
        uint256 originationDate;
        LoanStatus status;
    }

    struct PaymentRecord {
        uint256 loanId;
        euint64 principalPaid;         // encrypted principal portion
        euint64 interestPaid;          // encrypted interest portion
        euint64 remainingBalance;      // encrypted remaining balance
        uint256 paymentDate;
        bool late;
    }

    mapping(uint256 => CMBSLoan) private loans;
    mapping(uint256 => PaymentRecord[]) private payments;
    mapping(address => bool) public isLoanOfficer;
    mapping(address => bool) public isSpecialServicer;

    uint256 public loanCount;
    euint64 private _totalPortfolioBalance;
    euint64 private _totalPortfolioNOI;

    event LoanOriginated(uint256 indexed id, address borrower, PropertyType pType);
    event PaymentReceived(uint256 indexed loanId, uint256 paymentIndex);
    event LoanTransferredToSpecialServicing(uint256 indexed id);
    event LoanPaidOff(uint256 indexed id);

    modifier onlyLoanOfficer() {
        require(isLoanOfficer[msg.sender] || msg.sender == owner(), "Not loan officer");
        _;
    }

    modifier onlyServicer() {
        require(isSpecialServicer[msg.sender] || msg.sender == owner(), "Not servicer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPortfolioBalance = FHE.asEuint64(0);
        _totalPortfolioNOI = FHE.asEuint64(0);
        FHE.allowThis(_totalPortfolioBalance);
        FHE.allowThis(_totalPortfolioNOI);
        isLoanOfficer[msg.sender] = true;
        isSpecialServicer[msg.sender] = true;
    }

    function addLoanOfficer(address o) external onlyOwner { isLoanOfficer[o] = true; }
    function addServicer(address s) external onlyOwner { isSpecialServicer[s] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function originateLoan(
        address borrower,
        string calldata propertyAddress,
        PropertyType propType,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encAppraisal, bytes calldata aProof,
        externalEuint32 encLTV, bytes calldata lProof,
        externalEuint64 encNOI, bytes calldata nProof,
        externalEuint32 encDSCR, bytes calldata dProof,
        externalEuint32 encRate, bytes calldata rProof,
        externalEuint64 encReserve, bytes calldata resProof,
        uint256 maturityYears
    ) external onlyLoanOfficer whenNotPaused returns (uint256 id) {
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 appraisal = FHE.fromExternal(encAppraisal, aProof);
        euint32 ltv = FHE.fromExternal(encLTV, lProof);
        euint64 noi = FHE.fromExternal(encNOI, nProof);
        euint32 dscr = FHE.fromExternal(encDSCR, dProof);
        euint32 rate = FHE.fromExternal(encRate, rProof);
        euint64 reserve = FHE.fromExternal(encReserve, resProof);
        id = loanCount++;
        CMBSLoan storage _s0 = loans[id];
        _s0.borrower = borrower;
        _s0.propertyAddress = propertyAddress;
        _s0.propType = propType;
        _s0.principalBalanceUSD = principal;
        _s0.appraisedValueUSD = appraisal;
        _s0.ltvRatioBps = ltv;
        _s0.annualNOI_USD = noi;
        _s0.dscrBps = dscr;
        _s0.interestRateBps = rate;
        _s0.debtServiceReserveUSD = reserve;
        _s0.maturityDate = block.timestamp + maturityYears * 365 days;
        _s0.originationDate = block.timestamp;
        _s0.status = LoanStatus.Current;
        _totalPortfolioBalance = FHE.add(_totalPortfolioBalance, principal);
        _totalPortfolioNOI = FHE.add(_totalPortfolioNOI, noi);
        FHE.allowThis(loans[id].principalBalanceUSD);
        FHE.allow(loans[id].principalBalanceUSD, borrower);
        FHE.allowThis(loans[id].appraisedValueUSD);
        FHE.allow(loans[id].appraisedValueUSD, borrower);
        FHE.allowThis(loans[id].ltvRatioBps);
        FHE.allow(loans[id].ltvRatioBps, borrower);
        FHE.allowThis(loans[id].annualNOI_USD);
        FHE.allow(loans[id].annualNOI_USD, borrower);
        FHE.allowThis(loans[id].dscrBps);
        FHE.allow(loans[id].dscrBps, borrower);
        FHE.allowThis(loans[id].interestRateBps);
        FHE.allow(loans[id].interestRateBps, borrower);
        FHE.allowThis(loans[id].debtServiceReserveUSD);
        FHE.allowThis(_totalPortfolioBalance);
        FHE.allowThis(_totalPortfolioNOI);
        emit LoanOriginated(id, borrower, propType);
    }

    function receivePayment(
        uint256 loanId,
        externalEuint64 encPrincipalPaid, bytes calldata ppProof,
        externalEuint64 encInterestPaid, bytes calldata ipProof,
        bool late
    ) external onlyLoanOfficer nonReentrant {
        CMBSLoan storage l = loans[loanId];
        require(l.status == LoanStatus.Current || l.status == LoanStatus.WatchList, "Cannot pay");
        euint64 princPaid = FHE.fromExternal(encPrincipalPaid, ppProof);
        euint64 intPaid = FHE.fromExternal(encInterestPaid, ipProof);
        l.principalBalanceUSD = FHE.sub(l.principalBalanceUSD, princPaid);
        _totalPortfolioBalance = FHE.sub(_totalPortfolioBalance, princPaid);
        PaymentRecord memory rec = PaymentRecord({
            loanId: loanId, principalPaid: princPaid, interestPaid: intPaid,
            remainingBalance: l.principalBalanceUSD,
            paymentDate: block.timestamp, late: late
        });
        payments[loanId].push(rec);
        FHE.allowThis(l.principalBalanceUSD);
        FHE.allow(l.principalBalanceUSD, l.borrower);
        FHE.allowThis(_totalPortfolioBalance);
        FHE.allowThis(rec.principalPaid);
        FHE.allowThis(rec.interestPaid);
        FHE.allowThis(rec.remainingBalance);
        emit PaymentReceived(loanId, payments[loanId].length - 1);
    }

    function transferToSpecialServicing(uint256 loanId) external onlyServicer {
        loans[loanId].status = LoanStatus.SpecialServicing;
        emit LoanTransferredToSpecialServicing(loanId);
    }

    function markPaidOff(uint256 loanId) external onlyLoanOfficer {
        CMBSLoan storage l = loans[loanId];
        l.status = LoanStatus.Paid;
        _totalPortfolioBalance = FHE.sub(_totalPortfolioBalance, l.principalBalanceUSD);
        _totalPortfolioNOI = FHE.sub(_totalPortfolioNOI, l.annualNOI_USD);
        FHE.allowThis(_totalPortfolioBalance);
        FHE.allowThis(_totalPortfolioNOI);
        emit LoanPaidOff(loanId);
    }

    function allowPortfolioStats(address viewer) external onlyOwner {
        FHE.allow(_totalPortfolioBalance, viewer);
        FHE.allow(_totalPortfolioNOI, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}