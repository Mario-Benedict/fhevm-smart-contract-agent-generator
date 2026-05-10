// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EnterprisePrivateESGDisclosure
/// @notice Corporate ESG reporting with encrypted sub-metrics. Companies can
///         selectively disclose ESG scores to investors while keeping detailed
///         operational metrics private.
contract EnterprisePrivateESGDisclosure is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct ESGReport {
        string companyName;
        uint256 reportYear;
        // Environmental
        euint32 carbonEmissionsTonnes;
        euint16 renewableEnergyPct;
        euint32 waterUsageMegaliters;
        // Social
        euint8 workplaceSafetyScore;
        euint8 diversityScore;
        euint16 employeeSatisfactionScore;
        // Governance
        euint8 boardIndependencePct;
        euint8 executiveCompRatioBps;  // CEO to median worker ratio
        euint8 auditQualityScore;
        // Aggregates
        euint8 environmentalGrade;
        euint8 socialGrade;
        euint8 governanceGrade;
        euint8 compositeESGScore;
        bool submitted;
    }

    mapping(address => mapping(uint256 => ESGReport)) private reports;  // company => year => report
    mapping(address => bool) public isRating;  // ESG rating agencies
    mapping(address => mapping(address => bool)) public accessGrant; // company => investor => access

    event ReportSubmitted(address indexed company, uint256 year);
    event AccessGranted(address indexed company, address investor);

    constructor() Ownable(msg.sender) {}

    function addRatingAgency(address a) external onlyOwner { isRating[a] = true; }

    function grantAccess(address investor) external {
        accessGrant[msg.sender][investor] = true;
        _grantReportAccess(msg.sender, investor);
        emit AccessGranted(msg.sender, investor);
    }

    function _grantReportAccess(address company, address viewer) internal {
        uint256 currentYear = block.timestamp / 365 days + 1970;
        ESGReport storage r = reports[company][currentYear];
        if (r.submitted) {
            FHE.allow(r.compositeESGScore, viewer);
            FHE.allow(r.environmentalGrade, viewer);
            FHE.allow(r.socialGrade, viewer);
            FHE.allow(r.governanceGrade, viewer);
        }
    }

    function submitESGReport(
        uint256 year,
        externalEuint32 encCarbon, bytes calldata cProof,
        externalEuint16 encRenewable, bytes calldata rProof,
        externalEuint8 encSafety, bytes calldata sfProof,
        externalEuint8 encDiversity, bytes calldata dProof,
        externalEuint8 encBoardIndep, bytes calldata bProof,
        externalEuint8 encAudit, bytes calldata aProof
    ) external nonReentrant {
        require(!reports[msg.sender][year].submitted, "Already submitted");
        ESGReport storage r = reports[msg.sender][year];
        r.companyName = "Company";  // can be set publicly
        r.reportYear = year;
        r.carbonEmissionsTonnes = FHE.fromExternal(encCarbon, cProof);
        r.renewableEnergyPct = FHE.fromExternal(encRenewable, rProof);
        r.workplaceSafetyScore = FHE.fromExternal(encSafety, sfProof);
        r.diversityScore = FHE.fromExternal(encDiversity, dProof);
        r.boardIndependencePct = FHE.fromExternal(encBoardIndep, bProof);
        r.auditQualityScore = FHE.fromExternal(encAudit, aProof);
        // Initialize aggregate grades
        r.environmentalGrade = FHE.asEuint8(0);
        r.socialGrade = FHE.asEuint8(0);
        r.governanceGrade = FHE.asEuint8(0);
        r.compositeESGScore = FHE.asEuint8(0);
        r.submitted = true;
        FHE.allowThis(r.carbonEmissionsTonnes);
        FHE.allow(r.carbonEmissionsTonnes, msg.sender);
        FHE.allowThis(r.renewableEnergyPct);
        FHE.allow(r.renewableEnergyPct, msg.sender);
        FHE.allowThis(r.workplaceSafetyScore);
        FHE.allow(r.workplaceSafetyScore, msg.sender);
        FHE.allowThis(r.diversityScore);
        FHE.allow(r.diversityScore, msg.sender);
        FHE.allowThis(r.boardIndependencePct);
        FHE.allow(r.boardIndependencePct, msg.sender);
        FHE.allowThis(r.auditQualityScore);
        FHE.allow(r.auditQualityScore, msg.sender);
        FHE.allowThis(r.environmentalGrade);
        FHE.allowThis(r.socialGrade);
        FHE.allowThis(r.governanceGrade);
        FHE.allowThis(r.compositeESGScore);
        emit ReportSubmitted(msg.sender, year);
    }

    function assignGrades(
        address company, uint256 year,
        externalEuint8 encEnvGrade, bytes calldata eProof,
        externalEuint8 encSocGrade, bytes calldata sProof,
        externalEuint8 encGovGrade, bytes calldata gProof
    ) external {
        require(isRating[msg.sender], "Not rating agency");
        ESGReport storage r = reports[company][year];
        require(r.submitted, "No report");
        r.environmentalGrade = FHE.fromExternal(encEnvGrade, eProof);
        r.socialGrade = FHE.fromExternal(encSocGrade, sProof);
        r.governanceGrade = FHE.fromExternal(encGovGrade, gProof);
        r.compositeESGScore = FHE.div(
            FHE.add(FHE.add(r.environmentalGrade, r.socialGrade), r.governanceGrade),; // [arithmetic_overflow_underflow]
            ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
            3
        );
        FHE.allowThis(r.environmentalGrade);
        FHE.allow(r.environmentalGrade, company);
        FHE.allowThis(r.socialGrade);
        FHE.allow(r.socialGrade, company);
        FHE.allowThis(r.governanceGrade);
        FHE.allow(r.governanceGrade, company);
        FHE.allowThis(r.compositeESGScore);
        FHE.allow(r.compositeESGScore, company);
    }

    function allowFullReport(address company, uint256 year, address viewer) external onlyOwner {
        ESGReport storage r = reports[company][year];
        FHE.allow(r.carbonEmissionsTonnes, viewer);
        FHE.allow(r.workplaceSafetyScore, viewer);
        FHE.allow(r.diversityScore, viewer);
        FHE.allow(r.boardIndependencePct, viewer);
        FHE.allow(r.compositeESGScore, viewer);
    }
}
