// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedInfrastructurePPP
/// @notice Public-Private Partnership (PPP) for infrastructure: encrypted CAPEX,
///         encrypted revenue projections, and encrypted government viability gap funding.
contract EncryptedInfrastructurePPP is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum InfraType { Highway, Bridge, Airport, PowerPlant, WaterTreatment, Railway, Hospital }
    enum PPPModel { BOT, BOOT, BTO, Concession, DesignBuildFinanceOperate }
    enum ProjectStatus { RFP, BidEvaluation, Awarded, Construction, Operations, Handback }

    struct PPPProject {
        address concessionaire;
        address governmentBody;
        InfraType infraType;
        PPPModel pppModel;
        string projectName;
        euint64 capexUSD;               // encrypted CAPEX
        euint64 viabilityGapFundUSD;    // encrypted VGF from government
        euint64 annualRevenueProjection; // encrypted revenue projection
        euint64 actualAnnualRevenue;    // encrypted actual revenue
        euint32 concessionYears;        // encrypted concession period
        euint16 irr_Bps;               // encrypted IRR target
        euint64 debtServiceCoverageRatioBps; // encrypted DSCR
        uint256 constructionStart;
        uint256 operationsStart;
        ProjectStatus status;
    }

    struct TollCollection {
        uint256 projectId;
        euint64 collectedRevenueCents;  // encrypted period revenue
        euint32 userCount;              // encrypted users served
        uint256 periodStart;
        uint256 periodEnd;
        bool audited;
    }

    mapping(uint256 => PPPProject) private projects;
    mapping(uint256 => TollCollection[]) private collections;
    mapping(address => bool) public isGovernmentBody;
    mapping(address => bool) public isConcessionaire;
    mapping(address => bool) public isPPPAuditor;

    uint256 public projectCount;
    euint64 private _totalCapexPortfolio;
    euint64 private _totalVGFDisbursed;
    euint64 private _totalInfraRevenue;

    event ProjectRegistered(uint256 indexed id, InfraType iType, PPPModel model);
    event ProjectAwarded(uint256 indexed id, address concessionaire);
    event OperationsCommenced(uint256 indexed id);
    event RevenueCollected(uint256 indexed projectId, uint256 collectionIndex);

    modifier onlyAuditor() {
        require(isPPPAuditor[msg.sender] || msg.sender == owner(), "Not auditor");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCapexPortfolio = FHE.asEuint64(0);
        _totalVGFDisbursed = FHE.asEuint64(0);
        _totalInfraRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalCapexPortfolio);
        FHE.allowThis(_totalVGFDisbursed);
        FHE.allowThis(_totalInfraRevenue);
        isGovernmentBody[msg.sender] = true;
        isPPPAuditor[msg.sender] = true;
    }

    function addGovernment(address g) external onlyOwner { isGovernmentBody[g] = true; }
    function addConcessionaire(address c) external onlyOwner { isConcessionaire[c] = true; }
    function addAuditor(address a) external onlyOwner { isPPPAuditor[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerProject(
        address governmentBody, InfraType iType, PPPModel model, string calldata name,
        externalEuint64 encCapex, bytes calldata capProof,
        externalEuint64 encVGF, bytes calldata vgfProof,
        externalEuint64 encRevProj, bytes calldata rProof,
        externalEuint32 encYears, bytes calldata yProof,
        externalEuint16 encIRR, bytes calldata irrProof,
        uint256 constructionDays
    ) external whenNotPaused returns (uint256 id) {
        require(isGovernmentBody[governmentBody], "Not gov body");
        euint64 capex = FHE.fromExternal(encCapex, capProof);
        euint64 vgf = FHE.fromExternal(encVGF, vgfProof);
        euint64 revProj = FHE.fromExternal(encRevProj, rProof);
        euint32 concessionYrs = FHE.fromExternal(encYears, yProof);
        euint16 irr = FHE.fromExternal(encIRR, irrProof);
        id = projectCount++;
        PPPProject storage _s0 = projects[id];
        _s0.concessionaire = msg.sender;
        _s0.governmentBody = governmentBody;
        _s0.infraType = iType;
        _s0.pppModel = model;
        _s0.projectName = name;
        _s0.capexUSD = capex;
        _s0.viabilityGapFundUSD = vgf;
        _s0.annualRevenueProjection = revProj;
        _s0.actualAnnualRevenue = FHE.asEuint64(0);
        _s0.concessionYears = concessionYrs;
        _s0.irr_Bps = irr;
        _s0.debtServiceCoverageRatioBps = FHE.asEuint64(0);
        _s0.constructionStart = block.timestamp + constructionDays * 1 days;
        _s0.operationsStart = 0;
        _s0.status = ProjectStatus.RFP;
        _totalCapexPortfolio = FHE.add(_totalCapexPortfolio, capex);
        _totalVGFDisbursed = FHE.add(_totalVGFDisbursed, vgf);
        FHE.allowThis(projects[id].capexUSD); FHE.allow(projects[id].capexUSD, msg.sender); FHE.allow(projects[id].capexUSD, governmentBody);
        FHE.allowThis(projects[id].viabilityGapFundUSD); FHE.allow(projects[id].viabilityGapFundUSD, governmentBody);
        FHE.allowThis(projects[id].annualRevenueProjection); FHE.allow(projects[id].annualRevenueProjection, msg.sender);
        FHE.allowThis(projects[id].actualAnnualRevenue); FHE.allow(projects[id].actualAnnualRevenue, governmentBody);
        FHE.allowThis(projects[id].concessionYears);
        FHE.allowThis(projects[id].irr_Bps); FHE.allow(projects[id].irr_Bps, msg.sender);
        FHE.allowThis(projects[id].debtServiceCoverageRatioBps);
        FHE.allowThis(_totalCapexPortfolio);
        FHE.allowThis(_totalVGFDisbursed);
        emit ProjectRegistered(id, iType, model);
    }

    function awardProject(uint256 projectId, address concessionaire) external {
        require(isGovernmentBody[msg.sender], "Not gov body");
        projects[projectId].status = ProjectStatus.Awarded;
        projects[projectId].concessionaire = concessionaire;
        emit ProjectAwarded(projectId, concessionaire);
    }

    function commenceOperations(uint256 projectId) external onlyAuditor {
        projects[projectId].status = ProjectStatus.Operations;
        projects[projectId].operationsStart = block.timestamp;
        emit OperationsCommenced(projectId);
    }

    function recordRevenue(
        uint256 projectId,
        externalEuint64 encRevenue, bytes calldata rProof,
        externalEuint32 encUsers, bytes calldata uProof,
        uint256 periodStart, uint256 periodEnd
    ) external nonReentrant {
        PPPProject storage p = projects[projectId];
        require(p.concessionaire == msg.sender && p.status == ProjectStatus.Operations, "Not operator");
        euint64 revenue = FHE.fromExternal(encRevenue, rProof);
        euint32 users = FHE.fromExternal(encUsers, uProof);
        collections[projectId].push(TollCollection({
            projectId: projectId, collectedRevenueCents: revenue,
            userCount: users, periodStart: periodStart, periodEnd: periodEnd, audited: false
        }));
        p.actualAnnualRevenue = FHE.add(p.actualAnnualRevenue, revenue);
        _totalInfraRevenue = FHE.add(_totalInfraRevenue, revenue);
        FHE.allowThis(revenue); FHE.allow(revenue, p.governmentBody);
        FHE.allowThis(users);
        FHE.allowThis(p.actualAnnualRevenue); FHE.allow(p.actualAnnualRevenue, p.governmentBody);
        FHE.allowThis(_totalInfraRevenue);
        emit RevenueCollected(projectId, collections[projectId].length - 1);
    }

    function auditCollection(uint256 projectId, uint256 index) external onlyAuditor {
        collections[projectId][index].audited = true;
    }

    function allowPortfolioStats(address viewer) external onlyOwner {
        FHE.allow(_totalCapexPortfolio, viewer);
        FHE.allow(_totalVGFDisbursed, viewer);
        FHE.allow(_totalInfraRevenue, viewer);
    }
}
