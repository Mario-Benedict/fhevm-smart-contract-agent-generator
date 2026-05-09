// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedWildlifeConservationBond
/// @notice Green bond issuance for wildlife conservation.
///         Endangered species population counts, habitat area,
///         and poaching incident rates are encrypted impact metrics.
contract EncryptedWildlifeConservationBond is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SpeciesStatus { LeastConcern, NearThreatened, Vulnerable, Endangered, CriticallyEndangered }
    enum BondStatus { PreIssuance, Open, Active, Matured, DefaultedImpact }

    struct ConservationProject {
        uint256 projectId;
        string speciesName;
        string habitatRegion;
        SpeciesStatus speciesStatus;
        euint32 baselinePopulationCount;  // encrypted baseline animal count
        euint32 currentPopulationCount;   // encrypted current count
        euint32 habitatHectares;          // encrypted protected habitat area
        euint16 poachingIncidentsBps;     // encrypted annual poaching rate
        euint32 targetPopulationCount;    // encrypted KPI target
        euint64 fundingAllocationUSD;     // encrypted funding received
        bool active;
        uint256 startEpoch;
    }

    struct ConservationBond {
        uint256 bondId;
        euint64 faceValueUSD;             // encrypted bond size
        euint32 couponRateBps;            // encrypted coupon
        euint32 impactCouponBonusBps;     // encrypted impact-linked bonus
        euint64 totalRaised;              // encrypted capital raised
        BondStatus status;
        uint256 maturityDate;
        uint256[] linkedProjects;
    }

    struct BondInvestment {
        address investor;
        uint256 bondId;
        euint64 investmentUSD;            // encrypted investment amount
        euint64 couponsAccruedUSD;        // encrypted coupons earned
        bool redeemed;
    }

    mapping(uint256 => ConservationProject) private projects;
    mapping(uint256 => ConservationBond) private bonds;
    mapping(address => mapping(uint256 => BondInvestment)) private investments;
    mapping(address => bool) public isConservationVerifier;
    mapping(address => bool) public isImpactInvestor;

    uint256 public projectCount;
    uint256 public bondCount;
    euint64 private _totalConservationFunding;
    euint32 private _totalProtectedHectares;

    event ProjectRegistered(uint256 indexed id, string speciesName);
    event BondIssued(uint256 indexed bondId);
    event ImpactMetricUpdated(uint256 indexed projectId);
    event InvestorSubscribed(address indexed investor, uint256 bondId);
    event ImpactKPIMet(uint256 indexed projectId);
    event BondMatured(uint256 indexed bondId);

    modifier onlyVerifier() {
        require(isConservationVerifier[msg.sender] || msg.sender == owner(), "Not verifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalConservationFunding = FHE.asEuint64(0);
        _totalProtectedHectares = FHE.asEuint32(0);
        FHE.allowThis(_totalConservationFunding);
        FHE.allowThis(_totalProtectedHectares);
        isConservationVerifier[msg.sender] = true;
    }

    function addVerifier(address v) external onlyOwner { isConservationVerifier[v] = true; }
    function approveInvestor(address inv) external onlyOwner { isImpactInvestor[inv] = true; }

    function registerProject(
        string calldata speciesName,
        string calldata habitatRegion,
        SpeciesStatus speciesStatus,
        externalEuint32 encBaseline, bytes calldata baseProof,
        externalEuint32 encHectares, bytes calldata hectProof,
        externalEuint32 encTarget, bytes calldata targetProof
    ) external onlyVerifier returns (uint256 projectId) {
        projectId = projectCount++;
        ConservationProject storage p = projects[projectId];
        p.projectId = projectId;
        p.speciesName = speciesName;
        p.habitatRegion = habitatRegion;
        p.speciesStatus = speciesStatus;
        p.baselinePopulationCount = FHE.fromExternal(encBaseline, baseProof);
        p.currentPopulationCount = p.baselinePopulationCount;
        p.habitatHectares = FHE.fromExternal(encHectares, hectProof);
        p.poachingIncidentsBps = FHE.asEuint16(0);
        p.targetPopulationCount = FHE.fromExternal(encTarget, targetProof);
        p.fundingAllocationUSD = FHE.asEuint64(0);
        p.active = true;
        p.startEpoch = block.timestamp;

        _totalProtectedHectares = FHE.add(_totalProtectedHectares, p.habitatHectares);

        FHE.allowThis(p.baselinePopulationCount);
        FHE.allowThis(p.currentPopulationCount);
        FHE.allowThis(p.habitatHectares);
        FHE.allowThis(p.poachingIncidentsBps);
        FHE.allowThis(p.targetPopulationCount);
        FHE.allowThis(p.fundingAllocationUSD);
        FHE.allowThis(_totalProtectedHectares);

        emit ProjectRegistered(projectId, speciesName);
    }

    function updateImpactMetrics(
        uint256 projectId,
        externalEuint32 encCurrentPop, bytes calldata popProof,
        externalEuint16 encPoaching, bytes calldata poachProof
    ) external onlyVerifier {
        ConservationProject storage p = projects[projectId];
        euint32 currentPop = FHE.fromExternal(encCurrentPop, popProof);
        euint16 poaching = FHE.fromExternal(encPoaching, poachProof);
        p.currentPopulationCount = currentPop;
        p.poachingIncidentsBps = poaching;
        FHE.allowThis(p.currentPopulationCount);
        FHE.allowThis(p.poachingIncidentsBps);
        // Check if KPI met
        ebool kpiMet = FHE.ge(currentPop, p.targetPopulationCount);
        if (FHE.isInitialized(kpiMet)) emit ImpactKPIMet(projectId);
        emit ImpactMetricUpdated(projectId);
    }

    function issueBond(
        externalEuint64 encFaceValue, bytes calldata fvProof,
        externalEuint32 encCoupon, bytes calldata couponProof,
        externalEuint32 encImpactBonus, bytes calldata bonusProof,
        uint256 maturityDate,
        uint256[] calldata linkedProjectIds
    ) external onlyOwner returns (uint256 bondId) {
        bondId = bondCount++;
        ConservationBond storage b = bonds[bondId];
        b.bondId = bondId;
        b.faceValueUSD = FHE.fromExternal(encFaceValue, fvProof);
        b.couponRateBps = FHE.fromExternal(encCoupon, couponProof);
        b.impactCouponBonusBps = FHE.fromExternal(encImpactBonus, bonusProof);
        b.totalRaised = FHE.asEuint64(0);
        b.status = BondStatus.Open;
        b.maturityDate = maturityDate;
        for (uint256 i = 0; i < linkedProjectIds.length; i++) {
            b.linkedProjects.push(linkedProjectIds[i]);
        }
        FHE.allowThis(b.faceValueUSD);
        FHE.allowThis(b.couponRateBps);
        FHE.allowThis(b.impactCouponBonusBps);
        FHE.allowThis(b.totalRaised);
        emit BondIssued(bondId);
    }

    function subscribeBond(
        uint256 bondId,
        externalEuint64 encInvestment, bytes calldata invProof
    ) external nonReentrant {
        require(isImpactInvestor[msg.sender], "Not approved investor");
        ConservationBond storage b = bonds[bondId];
        require(b.status == BondStatus.Open, "Bond not open");
        euint64 investment = FHE.fromExternal(encInvestment, invProof);
        ebool fits = FHE.le(FHE.add(b.totalRaised, investment), b.faceValueUSD);
        euint64 actual = FHE.select(fits, investment, FHE.sub(b.faceValueUSD, b.totalRaised));
        b.totalRaised = FHE.add(b.totalRaised, actual);
        _totalConservationFunding = FHE.add(_totalConservationFunding, actual);
        BondInvestment storage inv = investments[msg.sender][bondId];
        inv.investor = msg.sender;
        inv.bondId = bondId;
        inv.investmentUSD = FHE.add(inv.investmentUSD, actual);
        inv.couponsAccruedUSD = FHE.asEuint64(0);
        FHE.allowThis(b.totalRaised); FHE.allowThis(_totalConservationFunding);
        FHE.allowThis(inv.investmentUSD); FHE.allow(inv.investmentUSD, msg.sender);
        FHE.allowThis(inv.couponsAccruedUSD); FHE.allow(inv.couponsAccruedUSD, msg.sender);
        emit InvestorSubscribed(msg.sender, bondId);
    }

    function distributeCoupon(
        uint256 bondId,
        address investor,
        externalEuint64 encCoupon, bytes calldata proof
    ) external onlyVerifier {
        euint64 coupon = FHE.fromExternal(encCoupon, proof);
        investments[investor][bondId].couponsAccruedUSD = FHE.add(
            investments[investor][bondId].couponsAccruedUSD, coupon
        );
        FHE.allowThis(investments[investor][bondId].couponsAccruedUSD);
        FHE.allow(investments[investor][bondId].couponsAccruedUSD, investor);
    }

    function matureBond(uint256 bondId) external onlyOwner {
        require(block.timestamp >= bonds[bondId].maturityDate, "Not matured");
        bonds[bondId].status = BondStatus.Matured;
        emit BondMatured(bondId);
    }

    function allowConservationStats(address viewer) external onlyOwner {
        FHE.allow(_totalConservationFunding, viewer);
        FHE.allow(_totalProtectedHectares, viewer);
    }
}
