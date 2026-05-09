// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCarbonTaxObligationRegistry
/// @notice Government-operated registry where companies report encrypted carbon emissions.
///         Tax obligations are computed privately. Regulators can audit without exposing
///         competitor data. Includes penalty calculation and offset credit netting.
contract EncryptedCarbonTaxObligationRegistry is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ReportingPeriod { QUARTERLY, ANNUAL }
    enum ComplianceStatus { UNREPORTED, PENDING, COMPLIANT, NON_COMPLIANT, EXEMPTED }

    struct EmissionsReport {
        euint64 scope1Emissions;     // encrypted direct emissions (tonnes CO2e)
        euint64 scope2Emissions;     // encrypted electricity-related emissions
        euint64 scope3Emissions;     // encrypted value chain emissions
        euint64 totalEmissions;      // encrypted total
        euint64 offsetCreditsUsed;   // encrypted voluntary offsets retired
        euint64 netTaxableEmissions; // encrypted taxable after offsets
        euint64 taxOwed;             // encrypted tax amount (USD cents)
        euint64 penaltyAmount;       // encrypted late/under-reporting penalty
        uint256 reportingYear;
        uint256 submissionTimestamp;
        ComplianceStatus status;
        bool audited;
    }

    struct CompanyProfile {
        string companyName;
        string sector;
        euint32 emissionAllowance;   // encrypted annual allowance (tonnes)
        euint64 cumulativeTaxPaid;   // encrypted lifetime taxes paid
        euint64 accumulatedPenalties;// encrypted unpaid penalties
        bool registered;
        bool exempted;
    }

    mapping(address => CompanyProfile) private companies;
    mapping(address => mapping(uint256 => EmissionsReport)) private reports;
    mapping(address => bool) public isRegulator;
    mapping(address => bool) public isAuditor;
    euint64 private _totalTaxRevenue;
    euint64 private _totalNationalEmissions;
    euint64 private _carbonTaxRateUSDPerTonne; // encrypted rate
    uint256 public constant REPORT_DEADLINE = 90 days;

    event CompanyRegistered(address indexed company, string name);
    event EmissionsReported(address indexed company, uint256 year);
    event TaxAssessed(address indexed company, uint256 year);
    event PenaltyIssued(address indexed company, uint256 year);
    event TaxPaid(address indexed company, uint256 year);
    event AuditCompleted(address indexed company, uint256 year);
    event ExemptionGranted(address indexed company);

    constructor(externalEuint64 encInitialTaxRate, bytes memory proof) Ownable(msg.sender) {
        _carbonTaxRateUSDPerTonne = FHE.fromExternal(encInitialTaxRate, proof);
        _totalTaxRevenue = FHE.asEuint64(0);
        _totalNationalEmissions = FHE.asEuint64(0);
        FHE.allowThis(_carbonTaxRateUSDPerTonne);
        FHE.allowThis(_totalTaxRevenue);
        FHE.allowThis(_totalNationalEmissions);
        isRegulator[msg.sender] = true;
        isAuditor[msg.sender] = true;
    }

    modifier onlyRegulator() {
        require(isRegulator[msg.sender], "Not regulator");
        _;
    }

    modifier onlyAuditor() {
        require(isAuditor[msg.sender], "Not auditor");
        _;
    }

    function addRegulator(address reg) external onlyOwner { isRegulator[reg] = true; }
    function addAuditor(address aud) external onlyOwner { isAuditor[aud] = true; }

    function updateTaxRate(externalEuint64 encRate, bytes calldata proof) external onlyRegulator {
        _carbonTaxRateUSDPerTonne = FHE.fromExternal(encRate, proof);
        FHE.allowThis(_carbonTaxRateUSDPerTonne);
    }

    function registerCompany(
        address company,
        string calldata name,
        string calldata sector,
        externalEuint32 encAllowance, bytes calldata proof
    ) external onlyRegulator {
        euint32 allowance = FHE.fromExternal(encAllowance, proof);
        companies[company] = CompanyProfile({
            companyName: name,
            sector: sector,
            emissionAllowance: allowance,
            cumulativeTaxPaid: FHE.asEuint64(0),
            accumulatedPenalties: FHE.asEuint64(0),
            registered: true,
            exempted: false
        });
        FHE.allowThis(companies[company].emissionAllowance);
        FHE.allow(companies[company].emissionAllowance, company);
        FHE.allowThis(companies[company].cumulativeTaxPaid);
        FHE.allowThis(companies[company].accumulatedPenalties);
        emit CompanyRegistered(company, name);
    }

    function submitEmissionsReport(
        uint256 year,
        externalEuint64 encScope1, bytes calldata s1Proof,
        externalEuint64 encScope2, bytes calldata s2Proof,
        externalEuint64 encScope3, bytes calldata s3Proof,
        externalEuint64 encOffsets, bytes calldata ofProof
    ) external nonReentrant {
        require(companies[msg.sender].registered, "Not registered");
        require(!companies[msg.sender].exempted, "Company exempted");
        euint64 s1 = FHE.fromExternal(encScope1, s1Proof);
        euint64 s2 = FHE.fromExternal(encScope2, s2Proof);
        euint64 s3 = FHE.fromExternal(encScope3, s3Proof);
        euint64 offsets = FHE.fromExternal(encOffsets, ofProof);
        euint64 total = FHE.add(FHE.add(s1, s2), s3);
        ebool offsetValid = FHE.le(offsets, total);
        euint64 validOffsets = FHE.select(offsetValid, offsets, total);
        euint64 netTaxable = FHE.sub(total, validOffsets);
        euint64 taxOwed = FHE.div(FHE.mul(netTaxable, _carbonTaxRateUSDPerTonne), 1);
        EmissionsReport storage rep = reports[msg.sender][year];
        rep.scope1Emissions = s1;
        rep.scope2Emissions = s2;
        rep.scope3Emissions = s3;
        rep.totalEmissions = total;
        rep.offsetCreditsUsed = validOffsets;
        rep.netTaxableEmissions = netTaxable;
        rep.taxOwed = taxOwed;
        rep.penaltyAmount = FHE.asEuint64(0);
        rep.reportingYear = year;
        rep.submissionTimestamp = block.timestamp;
        rep.status = ComplianceStatus.PENDING;
        rep.audited = false;
        _totalNationalEmissions = FHE.add(_totalNationalEmissions, total);
        FHE.allowThis(rep.scope1Emissions);
        FHE.allowThis(rep.scope2Emissions);
        FHE.allowThis(rep.scope3Emissions);
        FHE.allowThis(rep.totalEmissions);
        FHE.allow(rep.totalEmissions, msg.sender);
        FHE.allowThis(rep.netTaxableEmissions);
        FHE.allowThis(rep.taxOwed);
        FHE.allow(rep.taxOwed, msg.sender);
        FHE.allowThis(rep.penaltyAmount);
        FHE.allowThis(_totalNationalEmissions);
        emit EmissionsReported(msg.sender, year);
        emit TaxAssessed(msg.sender, year);
    }

    function payTax(uint256 year) external nonReentrant {
        EmissionsReport storage rep = reports[msg.sender][year];
        require(rep.status == ComplianceStatus.PENDING, "Not pending");
        companies[msg.sender].cumulativeTaxPaid = FHE.add(
            companies[msg.sender].cumulativeTaxPaid, rep.taxOwed
        );
        _totalTaxRevenue = FHE.add(_totalTaxRevenue, rep.taxOwed);
        rep.taxOwed = FHE.asEuint64(0);
        rep.status = ComplianceStatus.COMPLIANT;
        FHE.allowThis(companies[msg.sender].cumulativeTaxPaid);
        FHE.allowThis(_totalTaxRevenue);
        FHE.allowThis(rep.taxOwed);
        emit TaxPaid(msg.sender, year);
    }

    function issuePenalty(
        address company, uint256 year,
        externalEuint64 encPenalty, bytes calldata proof
    ) external onlyRegulator {
        euint64 penalty = FHE.fromExternal(encPenalty, proof);
        reports[company][year].penaltyAmount = FHE.add(reports[company][year].penaltyAmount, penalty);
        companies[company].accumulatedPenalties = FHE.add(companies[company].accumulatedPenalties, penalty);
        reports[company][year].status = ComplianceStatus.NON_COMPLIANT;
        FHE.allowThis(reports[company][year].penaltyAmount);
        FHE.allow(reports[company][year].penaltyAmount, company);
        FHE.allowThis(companies[company].accumulatedPenalties);
        emit PenaltyIssued(company, year);
    }

    function auditReport(address company, uint256 year) external onlyAuditor {
        reports[company][year].audited = true;
        emit AuditCompleted(company, year);
    }

    function grantExemption(address company) external onlyRegulator {
        companies[company].exempted = true;
        emit ExemptionGranted(company);
    }

    function allowRegulatorView(address company, uint256 year) external onlyRegulator {
        FHE.allow(reports[company][year].totalEmissions, msg.sender);
        FHE.allow(reports[company][year].netTaxableEmissions, msg.sender);
        FHE.allow(reports[company][year].taxOwed, msg.sender);
        FHE.allow(companies[company].cumulativeTaxPaid, msg.sender);
    }

    function allowNationalStats(address viewer) external onlyOwner {
        FHE.allow(_totalTaxRevenue, viewer);
        FHE.allow(_totalNationalEmissions, viewer);
    }
}
