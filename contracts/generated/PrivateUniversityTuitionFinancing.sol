// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateUniversityTuitionFinancing
/// @notice Income share agreement (ISA) platform: encrypted future earnings projections,
///         confidential repayment caps, and private income verification for student funding.
contract PrivateUniversityTuitionFinancing is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum DegreeType { STEM, BUSINESS, ARTS_HUMANITIES, LAW, MEDICINE, ENGINEERING }
    enum ISAStatus { ACTIVE, DEFERMENT, REPAYMENT, COMPLETED, DEFAULTED }

    struct IncomeShareAgreement {
        address student;
        DegreeType degreeType;
        euint64 fundingAmountUSD;         // encrypted amount funded
        euint64 incomeSharePct;           // encrypted share percentage (bps)
        euint64 paymentCapUSD;            // encrypted total repayment cap
        euint64 minimumIncomeThresholdUSD; // encrypted minimum income to trigger repayment
        euint64 totalPaidUSD;             // encrypted amount repaid
        euint64 latestVerifiedIncomeUSD;  // encrypted latest verified annual income
        euint64 projectedEarningsUSD;     // encrypted projected lifetime earnings
        euint32 repaymentTermYears;       // encrypted max repayment term
        uint256 agreementDate;
        ISAStatus status;
        bool incomeVerified;
    }

    struct SchoolPartnership {
        string schoolName;
        euint64 averageStartingSalaryUSD; // encrypted average graduate salary
        euint64 employmentRateBps;        // encrypted placement rate
        euint64 fundingLimitPerStudentUSD; // encrypted per-student limit
        euint64 totalFundingCommittedUSD; // encrypted total committed
        bool approved;
    }

    mapping(uint256 => IncomeShareAgreement) private agreements;
    mapping(bytes32 => SchoolPartnership) private schools;
    mapping(address => bool) public isISAProvider;
    mapping(address => bool) public isIncomeVerifier;
    mapping(address => uint256) public studentAgreementId;

    uint256 public agreementCount;
    euint64 private _totalFundingDeployed;
    euint64 private _totalRepayments;
    euint64 private _portfolioYieldBps;

    event ISAOriginated(uint256 indexed agreementId, address student, DegreeType degree);
    event IncomeVerified(uint256 indexed agreementId, address student);
    event RepaymentMade(uint256 indexed agreementId, address student);
    event ISACompleted(uint256 indexed agreementId);
    event ISADefaulted(uint256 indexed agreementId);
    event DefermentGranted(uint256 indexed agreementId);

    constructor() Ownable(msg.sender) {
        _totalFundingDeployed = FHE.asEuint64(0);
        _totalRepayments = FHE.asEuint64(0);
        _portfolioYieldBps = FHE.asEuint64(0);
        FHE.allowThis(_totalFundingDeployed);
        FHE.allowThis(_totalRepayments);
        FHE.allowThis(_portfolioYieldBps);
        isISAProvider[msg.sender] = true;
        isIncomeVerifier[msg.sender] = true;
    }

    modifier onlyISAProvider() { require(isISAProvider[msg.sender], "Not ISA provider"); _; }
    modifier onlyIncomeVerifier() { require(isIncomeVerifier[msg.sender], "Not income verifier"); _; }

    function registerSchool(
        bytes32 schoolId,
        string calldata name,
        externalEuint64 encAvgSalary, bytes calldata asProof,
        externalEuint64 encEmploymentRate, bytes calldata erProof,
        externalEuint64 encFundingLimit, bytes calldata flProof
    ) external onlyISAProvider {
        SchoolPartnership storage sp = schools[schoolId];
        sp.schoolName = name;
        sp.averageStartingSalaryUSD = FHE.fromExternal(encAvgSalary, asProof);
        sp.employmentRateBps = FHE.fromExternal(encEmploymentRate, erProof);
        sp.fundingLimitPerStudentUSD = FHE.fromExternal(encFundingLimit, flProof);
        sp.totalFundingCommittedUSD = FHE.asEuint64(0);
        sp.approved = true;
        FHE.allowThis(sp.averageStartingSalaryUSD);
        FHE.allowThis(sp.employmentRateBps);
        FHE.allowThis(sp.fundingLimitPerStudentUSD);
        FHE.allowThis(sp.totalFundingCommittedUSD);
    }

    function originateISA(
        address student,
        bytes32 schoolId,
        DegreeType degreeType,
        externalEuint64 encFunding, bytes calldata fProof,
        externalEuint64 encIncomeShare, bytes calldata isProof,
        externalEuint64 encPaymentCap, bytes calldata pcProof,
        externalEuint64 encMinIncome, bytes calldata miProof,
        externalEuint32 encTerm, bytes calldata tProof
    ) external onlyISAProvider returns (uint256 agreementId) {
        require(schools[schoolId].approved, "School not approved");
        require(studentAgreementId[student] == 0, "Student already funded");
        euint64 funding = FHE.fromExternal(encFunding, fProof);
        // Verify within school funding limit
        SchoolPartnership storage sp = schools[schoolId];
        ebool withinLimit = FHE.le(funding, sp.fundingLimitPerStudentUSD);
        euint64 actualFunding = FHE.select(withinLimit, funding, sp.fundingLimitPerStudentUSD);
        euint64 incomeShare = FHE.fromExternal(encIncomeShare, isProof);
        euint64 paymentCap = FHE.fromExternal(encPaymentCap, pcProof);
        euint64 minIncome = FHE.fromExternal(encMinIncome, miProof);
        euint32 term = FHE.fromExternal(encTerm, tProof);
        // Project earnings: school avg salary * employment rate
        euint64 projectedEarnings = FHE.div(FHE.mul(sp.averageStartingSalaryUSD, sp.employmentRateBps), 10000);
        agreementId = agreementCount++;
        if (agreementId == 0) agreementId = 1; // avoid 0 mapping
        IncomeShareAgreement storage isa = agreements[agreementId];
        isa.student = student;
        isa.degreeType = degreeType;
        isa.fundingAmountUSD = actualFunding;
        isa.incomeSharePct = incomeShare;
        isa.paymentCapUSD = paymentCap;
        isa.minimumIncomeThresholdUSD = minIncome;
        isa.totalPaidUSD = FHE.asEuint64(0);
        isa.latestVerifiedIncomeUSD = FHE.asEuint64(0);
        isa.projectedEarningsUSD = projectedEarnings;
        isa.repaymentTermYears = term;
        isa.agreementDate = block.timestamp;
        isa.status = ISAStatus.ACTIVE;
        sp.totalFundingCommittedUSD = FHE.add(sp.totalFundingCommittedUSD, actualFunding);
        _totalFundingDeployed = FHE.add(_totalFundingDeployed, actualFunding);
        studentAgreementId[student] = agreementId;
        FHE.allowThis(isa.fundingAmountUSD);
        FHE.allow(isa.fundingAmountUSD, student);
        FHE.allowThis(isa.incomeSharePct);
        FHE.allow(isa.incomeSharePct, student);
        FHE.allowThis(isa.paymentCapUSD);
        FHE.allow(isa.paymentCapUSD, student);
        FHE.allowThis(isa.minimumIncomeThresholdUSD);
        FHE.allow(isa.minimumIncomeThresholdUSD, student);
        FHE.allowThis(isa.totalPaidUSD);
        FHE.allow(isa.totalPaidUSD, student);
        FHE.allowThis(isa.projectedEarningsUSD);
        FHE.allow(isa.projectedEarningsUSD, student);
        FHE.allowThis(sp.totalFundingCommittedUSD);
        FHE.allowThis(_totalFundingDeployed);
        emit ISAOriginated(agreementId, student, degreeType);
    }

    function verifyIncome(
        uint256 agreementId,
        externalEuint64 encIncome, bytes calldata iProof
    ) external onlyIncomeVerifier {
        IncomeShareAgreement storage isa = agreements[agreementId];
        euint64 income = FHE.fromExternal(encIncome, iProof);
        isa.latestVerifiedIncomeUSD = income;
        isa.incomeVerified = true;
        // Determine repayment amount: incomeSharePct * max(income - minThreshold, 0)
        ebool aboveThreshold = FHE.gt(income, isa.minimumIncomeThresholdUSD);
        euint64 repayableIncome = FHE.select(aboveThreshold,
            FHE.sub(income, isa.minimumIncomeThresholdUSD), FHE.asEuint64(0));
        euint64 annualRepayment = FHE.div(FHE.mul(repayableIncome, isa.incomeSharePct), 10000);
        if (FHE.decrypt(aboveThreshold)) isa.status = ISAStatus.REPAYMENT;
        FHE.allowThis(isa.latestVerifiedIncomeUSD);
        FHE.allow(isa.latestVerifiedIncomeUSD, isa.student);
        FHE.allow(annualRepayment, isa.student);
        emit IncomeVerified(agreementId, isa.student);
    }

    function makeRepayment(uint256 agreementId, externalEuint64 encPayment, bytes calldata pProof) external nonReentrant {
        IncomeShareAgreement storage isa = agreements[agreementId];
        require(isa.student == msg.sender, "Not student");
        require(isa.status == ISAStatus.REPAYMENT, "Not in repayment");
        euint64 payment = FHE.fromExternal(encPayment, pProof);
        euint64 remaining = FHE.sub(isa.paymentCapUSD, isa.totalPaidUSD);
        euint64 actualPayment = FHE.select(FHE.le(payment, remaining), payment, remaining);
        isa.totalPaidUSD = FHE.add(isa.totalPaidUSD, actualPayment);
        _totalRepayments = FHE.add(_totalRepayments, actualPayment);
        // Check if cap reached
        ebool capReached = FHE.ge(isa.totalPaidUSD, isa.paymentCapUSD);
        if (FHE.decrypt(capReached)) {
            isa.status = ISAStatus.COMPLETED;
            emit ISACompleted(agreementId);
        }
        FHE.allowThis(isa.totalPaidUSD);
        FHE.allow(isa.totalPaidUSD, msg.sender);
        FHE.allowThis(_totalRepayments);
        emit RepaymentMade(agreementId, msg.sender);
    }

    function grantDeferment(uint256 agreementId) external onlyISAProvider {
        IncomeShareAgreement storage isa = agreements[agreementId];
        isa.status = ISAStatus.DEFERMENT;
        emit DefermentGranted(agreementId);
    }

    function markDefault(uint256 agreementId) external onlyISAProvider {
        agreements[agreementId].status = ISAStatus.DEFAULTED;
        emit ISADefaulted(agreementId);
    }

    function addISAProvider(address p) external onlyOwner { isISAProvider[p] = true; }
    function addIncomeVerifier(address iv) external onlyOwner { isIncomeVerifier[iv] = true; }
    function allowPortfolioStats(address investor) external onlyISAProvider {
        FHE.allow(_totalFundingDeployed, investor);
        FHE.allow(_totalRepayments, investor);
    }
}
