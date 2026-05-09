// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedMortgageOrigination - Confidential home loan underwriting with encrypted DTI and LTV ratios
contract EncryptedMortgageOrigination is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant UNDERWRITER_ROLE = keccak256("UNDERWRITER_ROLE");
    bytes32 public constant APPRAISER_ROLE   = keccak256("APPRAISER_ROLE");

    enum LoanStatus { Applied, Underwriting, Approved, Rejected, Funded, Defaulted }

    struct MortgageApplication {
        address  borrower;
        euint64  loanAmount;
        euint64  propertyValue;
        euint8   ltvRatio;          // loan-to-value bps/10
        euint8   dtiRatio;          // debt-to-income bps/10
        euint8   creditScore;       // 3-digit FICO mapped 0-100
        euint16  interestRateBps;   // e.g. 650 = 6.50%
        euint16  termMonths;
        LoanStatus status;
        uint256  appliedAt;
        bool     insuranceRequired; // PMI if LTV > 80%
    }

    struct MonthlyPayment {
        uint256 dueDate;
        euint64 principalPart;
        euint64 interestPart;
        bool    paid;
    }

    mapping(uint256 => MortgageApplication) public applications;
    mapping(uint256 => MonthlyPayment[])    private schedule;
    mapping(address => uint256[])           public borrowerLoans;
    uint256 public applicationCount;

    event ApplicationReceived(uint256 indexed loanId, address indexed borrower);
    event PropertyAppraised(uint256 indexed loanId);
    event LoanDecision(uint256 indexed loanId, LoanStatus status);
    event LoanFunded(uint256 indexed loanId);
    event PaymentMade(uint256 indexed loanId, uint256 paymentIndex);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UNDERWRITER_ROLE,   msg.sender);
        _grantRole(APPRAISER_ROLE,     msg.sender);
    }

    function applyForMortgage(
        externalEuint64 encLoan,    bytes calldata loanProof,
        externalEuint8 encCredit,  bytes calldata creditProof,
        externalEuint16 encTerm,    bytes calldata termProof
    ) external returns (uint256 loanId) {
        loanId = applicationCount++;
        MortgageApplication storage a = applications[loanId];
        a.borrower     = msg.sender;
        a.loanAmount   = FHE.fromExternal(encLoan,   loanProof);
        a.creditScore  = FHE.fromExternal(encCredit, creditProof);
        a.termMonths   = FHE.fromExternal(encTerm,   termProof);
        a.propertyValue = FHE.asEuint64(0);
        a.ltvRatio     = FHE.asEuint8(0);
        a.dtiRatio     = FHE.asEuint8(0);
        a.interestRateBps = FHE.asEuint16(0);
        a.status       = LoanStatus.Applied;
        a.appliedAt    = block.timestamp;
        FHE.allowThis(a.loanAmount);  FHE.allowThis(a.creditScore);
        FHE.allowThis(a.termMonths);  FHE.allowThis(a.propertyValue);
        FHE.allowThis(a.ltvRatio);    FHE.allowThis(a.dtiRatio);
        FHE.allowThis(a.interestRateBps);
        FHE.allow(a.loanAmount, msg.sender);
        // FHE.allow to underwriter admin skipped (getRoleAdmin returns bytes32, not address)
        borrowerLoans[msg.sender].push(loanId);
        emit ApplicationReceived(loanId, msg.sender);
    }

    function appraise(
        uint256 loanId,
        uint8 ltvRatioValue,
        bool insuranceRequiredValue,
        externalEuint64 encValue, bytes calldata valueProof
    ) external onlyRole(APPRAISER_ROLE) {
        MortgageApplication storage a = applications[loanId];
        a.propertyValue = FHE.fromExternal(encValue, valueProof);
        // LTV provided by appraiser after off-chain computation (encrypted divisor not supported)
        a.ltvRatio = FHE.asEuint8(ltvRatioValue);
        a.insuranceRequired = insuranceRequiredValue;
        a.status = LoanStatus.Underwriting;
        FHE.allowThis(a.propertyValue); FHE.allowThis(a.ltvRatio);
        FHE.allow(a.propertyValue, a.borrower);        // FHE.allow to role admin skipped (getRoleAdmin returns bytes32, not address)
        emit PropertyAppraised(loanId);
    }

    function underwrite(
        uint256 loanId,
        externalEuint8 encDti,  bytes calldata dtiProof,
        externalEuint16 encRate, bytes calldata rateProof,
        bool approve
    ) external onlyRole(UNDERWRITER_ROLE) {
        MortgageApplication storage a = applications[loanId];
        require(a.status == LoanStatus.Underwriting, "Wrong status");
        a.dtiRatio        = FHE.fromExternal(encDti,  dtiProof);
        a.interestRateBps = FHE.fromExternal(encRate, rateProof);
        a.status = approve ? LoanStatus.Approved : LoanStatus.Rejected;
        FHE.allowThis(a.dtiRatio); FHE.allowThis(a.interestRateBps);
        FHE.allow(a.dtiRatio, a.borrower);
        FHE.allow(a.interestRateBps, a.borrower);
        emit LoanDecision(loanId, a.status);
    }

    function fundLoan(uint256 loanId) external onlyRole(UNDERWRITER_ROLE) nonReentrant {
        MortgageApplication storage a = applications[loanId];
        require(a.status == LoanStatus.Approved, "Not approved");
        a.status = LoanStatus.Funded;
        FHE.allowTransient(a.loanAmount, a.borrower);
        emit LoanFunded(loanId);
    }

    function recordPayment(uint256 loanId, uint256 paymentIdx) external nonReentrant {
        MortgageApplication storage a = applications[loanId];
        require(a.borrower == msg.sender, "Not borrower");
        require(a.status == LoanStatus.Funded, "Not funded");
        schedule[loanId][paymentIdx].paid = true;
        emit PaymentMade(loanId, paymentIdx);
    }
}
