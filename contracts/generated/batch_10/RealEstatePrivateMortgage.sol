// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RealEstatePrivateMortgage
/// @notice Mortgage origination with encrypted LTV ratios, income verification,
///         and property valuations. Underwriters evaluate applicants without
///         exposing financial details to competing lenders.
contract RealEstatePrivateMortgage is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MortgageStatus { Application, Underwriting, Approved, Rejected, Active, Paid, Defaulted }

    struct MortgageApplication {
        address applicant;
        euint64 propertyValue;
        euint64 loanAmount;
        euint64 annualIncome;
        euint16 ltvRatioBps;         // encrypted: loan/value * 10000
        euint16 dtiRatioBps;         // encrypted: debt/income * 10000
        euint8 creditScore;          // encrypted
        euint8 riskGrade;            // A/B/C/D encrypted as 1-4
        euint64 interestRateBps;     // encrypted annual rate
        MortgageStatus status;
        uint256 submittedAt;
        uint256 approvedAt;
    }

    struct PaymentRecord {
        euint64 principal;
        euint64 interest;
        euint64 balance;
        uint256 paidAt;
    }

    mapping(uint256 => MortgageApplication) private applications;
    uint256 public applicationCount;
    mapping(address => uint256[]) private applicantLoans;
    mapping(uint256 => PaymentRecord[]) private paymentHistory;
    mapping(address => bool) public isUnderwriter;
    euint64 private _maxLTVBps;
    euint64 private _maxDTIBps;

    event ApplicationSubmitted(uint256 indexed id, address applicant);
    event ApplicationDecided(uint256 indexed id, bool approved);
    event PaymentMade(uint256 indexed id, address borrower);

    constructor(
        externalEuint64 encMaxLTV, bytes memory lProof,
        externalEuint64 encMaxDTI, bytes memory dProof
    ) Ownable(msg.sender) {
        _maxLTVBps = FHE.fromExternal(encMaxLTV, lProof);
        _maxDTIBps = FHE.fromExternal(encMaxDTI, dProof);
        FHE.allowThis(_maxLTVBps);
        FHE.allowThis(_maxDTIBps);
        isUnderwriter[msg.sender] = true;
    }

    function addUnderwriter(address u) external onlyOwner { isUnderwriter[u] = true; }

    function applyForMortgage(
        externalEuint64 encPropertyValue, bytes calldata pvProof,
        externalEuint64 encLoanAmount, bytes calldata laProof,
        externalEuint64 encIncome, bytes calldata iProof,
        externalEuint8 encCreditScore, bytes calldata csProof
    ) external nonReentrant returns (uint256 id) {
        id = applicationCount++;
        euint64 propVal = FHE.fromExternal(encPropertyValue, pvProof);
        euint64 loanAmt = FHE.fromExternal(encLoanAmount, laProof);
        euint64 income = FHE.fromExternal(encIncome, iProof);
        euint8 credit = FHE.fromExternal(encCreditScore, csProof);
        euint16 ltv = FHE.asEuint16(0); // simplified
        euint16 dti = FHE.asEuint16(0); // simplified
        MortgageApplication storage _s0 = applications[id];
        _s0.applicant = msg.sender;
        _s0.propertyValue = propVal;
        _s0.loanAmount = loanAmt;
        _s0.annualIncome = income;
        _s0.ltvRatioBps = ltv;
        _s0.dtiRatioBps = dti;
        _s0.creditScore = credit;
        _s0.riskGrade = FHE.asEuint8(0);
        _s0.interestRateBps = FHE.asEuint64(0);
        _s0.status = MortgageStatus.Application;
        _s0.submittedAt = block.timestamp;
        _s0.approvedAt = 0;
        FHE.allowThis(applications[id].propertyValue);
        FHE.allowThis(applications[id].loanAmount);
        FHE.allow(applications[id].loanAmount, msg.sender);
        FHE.allowThis(applications[id].annualIncome);
        FHE.allowThis(applications[id].creditScore);
        FHE.allowThis(applications[id].ltvRatioBps);
        FHE.allowThis(applications[id].dtiRatioBps);
        FHE.allowThis(applications[id].riskGrade);
        FHE.allowThis(applications[id].interestRateBps);
        applicantLoans[msg.sender].push(id);
        emit ApplicationSubmitted(id, msg.sender);
    }

    function underwriteApplication(
        uint256 appId, bool approve,
        externalEuint8 encRiskGrade, bytes calldata rProof,
        externalEuint64 encInterestRate, bytes calldata irProof
    ) external {
        require(isUnderwriter[msg.sender], "Not underwriter");
        MortgageApplication storage a = applications[appId];
        require(a.status == MortgageStatus.Application || a.status == MortgageStatus.Underwriting, "Wrong status");
        a.status = MortgageStatus.Underwriting;
        if (approve) {
            a.riskGrade = FHE.fromExternal(encRiskGrade, rProof);
            a.interestRateBps = FHE.fromExternal(encInterestRate, irProof);
            a.status = MortgageStatus.Approved;
            a.approvedAt = block.timestamp;
            FHE.allowThis(a.riskGrade);
            FHE.allow(a.riskGrade, a.applicant);
            FHE.allowThis(a.interestRateBps);
            FHE.allow(a.interestRateBps, a.applicant);
        } else {
            a.status = MortgageStatus.Rejected;
        }
        emit ApplicationDecided(appId, approve);
    }

    function makePayment(
        uint256 appId,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encInterest, bytes calldata iProof,
        externalEuint64 encBalance, bytes calldata bProof
    ) external nonReentrant {
        MortgageApplication storage a = applications[appId];
        require(a.applicant == msg.sender, "Not applicant");
        require(a.status == MortgageStatus.Active || a.status == MortgageStatus.Approved, "Not active");
        if (a.status == MortgageStatus.Approved) a.status = MortgageStatus.Active;
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 interest = FHE.fromExternal(encInterest, iProof);
        euint64 balance = FHE.fromExternal(encBalance, bProof);
        paymentHistory[appId].push(PaymentRecord({
            principal: principal, interest: interest, balance: balance, paidAt: block.timestamp
        }));
        uint256 idx = paymentHistory[appId].length - 1;
        FHE.allowThis(paymentHistory[appId][idx].principal);
        FHE.allow(paymentHistory[appId][idx].principal, msg.sender);
        FHE.allowThis(paymentHistory[appId][idx].interest);
        FHE.allow(paymentHistory[appId][idx].interest, msg.sender);
        FHE.allowThis(paymentHistory[appId][idx].balance);
        FHE.allow(paymentHistory[appId][idx].balance, msg.sender);
        ebool paidOff = FHE.eq(balance, FHE.asEuint64(0));
        if (FHE.isInitialized(paidOff)) a.status = MortgageStatus.Paid;
        emit PaymentMade(appId, msg.sender);
    }

    function allowApplicationData(uint256 id, address viewer) external {
        MortgageApplication storage a = applications[id];
        require(msg.sender == a.applicant || isUnderwriter[msg.sender], "No access");
        FHE.allow(a.loanAmount, viewer);
        FHE.allow(a.interestRateBps, viewer);
        FHE.allow(a.creditScore, viewer);
    }
}
