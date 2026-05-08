// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateGeothermalEnergyRoyalty
/// @notice Geothermal energy production royalty distribution with encrypted
///         well output, steam quality, megawatt-hour production, and
///         royalty payment calculations per energy developer.
contract PrivateGeothermalEnergyRoyalty is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum WellStatus { Exploration, Development, Production, Workover, Abandoned }
    enum SteamQuality { WetSteam, DrySteam, HighEnthalpy, BinaryFluid }

    struct GeothermalWell {
        uint256 wellId;
        string wellName;
        string fieldLocation;
        SteamQuality steamQuality;
        WellStatus status;
        euint32 reservoirTempCelsius;  // encrypted reservoir temperature
        euint64 installedCapacityKW;   // encrypted nameplate capacity
        euint64 cumulativeMWhProduced; // encrypted lifetime production
        euint32 capacityFactorBps;     // encrypted capacity factor
        euint32 steamPressureBarX10;   // encrypted steam pressure * 10
        euint64 royaltyPaidUSD;        // encrypted royalties paid to date
        address developer;
    }

    struct ProductionRecord {
        uint256 wellId;
        euint64 grossMWhProduced;      // encrypted gross generation
        euint64 ownUseMWh;             // encrypted parasitic load
        euint64 netMWhExported;        // encrypted net export
        euint64 revenueUSD;            // encrypted gross revenue
        euint64 royaltyAmountUSD;      // encrypted royalty payment
        uint256 periodStart;
        uint256 periodEnd;
        bool audited;
    }

    struct RoyaltyTerms {
        euint32 basRoyaltyRateBps;     // encrypted base royalty %
        euint32 progressiveTierBps;    // encrypted higher-tier royalty
        euint64 tierThresholdMWh;      // encrypted threshold for higher rate
        euint64 minimumAnnualRoyalty;  // encrypted floor royalty
        bool active;
    }

    mapping(uint256 => GeothermalWell) private wells;
    mapping(uint256 => ProductionRecord[]) private productionHistory;
    mapping(address => RoyaltyTerms) private royaltyTerms;
    mapping(address => bool) public isDeveloper;
    mapping(address => bool) public isGovernmentRepresentative;

    uint256 public wellCount;
    euint64 private _totalMWhGenerated;
    euint64 private _totalRoyaltiesCollected;
    euint64 private _totalRevenueAcrossWells;

    event WellRegistered(uint256 indexed wellId, string wellName, SteamQuality steamQuality);
    event ProductionRecorded(uint256 indexed wellId, uint256 recordIndex);
    event RoyaltyPaid(uint256 indexed wellId, address developer);
    event WellStatusChanged(uint256 indexed wellId, WellStatus newStatus);

    modifier onlyGovernment() {
        require(isGovernmentRepresentative[msg.sender] || msg.sender == owner(), "Not government rep");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalMWhGenerated = FHE.asEuint64(0);
        _totalRoyaltiesCollected = FHE.asEuint64(0);
        _totalRevenueAcrossWells = FHE.asEuint64(0);
        FHE.allowThis(_totalMWhGenerated);
        FHE.allowThis(_totalRoyaltiesCollected);
        FHE.allowThis(_totalRevenueAcrossWells);
        isGovernmentRepresentative[msg.sender] = true;
    }

    function addGovernmentRep(address rep) external onlyOwner { isGovernmentRepresentative[rep] = true; }
    function registerDeveloper(address dev) external onlyOwner { isDeveloper[dev] = true; }

    function setRoyaltyTerms(
        address developer,
        externalEuint32 encBaseRate, bytes calldata baseProof,
        externalEuint32 encProgRate, bytes calldata progProof,
        externalEuint64 encTierThreshold, bytes calldata tierProof,
        externalEuint64 encMinAnnual, bytes calldata minProof
    ) external onlyGovernment {
        royaltyTerms[developer].basRoyaltyRateBps = FHE.fromExternal(encBaseRate, baseProof);
        royaltyTerms[developer].progressiveTierBps = FHE.fromExternal(encProgRate, progProof);
        royaltyTerms[developer].tierThresholdMWh = FHE.fromExternal(encTierThreshold, tierProof);
        royaltyTerms[developer].minimumAnnualRoyalty = FHE.fromExternal(encMinAnnual, minProof);
        royaltyTerms[developer].active = true;
        FHE.allowThis(royaltyTerms[developer].basRoyaltyRateBps);
        FHE.allowThis(royaltyTerms[developer].progressiveTierBps);
        FHE.allowThis(royaltyTerms[developer].tierThresholdMWh);
        FHE.allowThis(royaltyTerms[developer].minimumAnnualRoyalty);
    }

    function registerWell(
        string calldata wellName,
        string calldata fieldLocation,
        SteamQuality steamQuality,
        externalEuint32 encReservoirTemp, bytes calldata tempProof,
        externalEuint64 encCapacityKW, bytes calldata capProof,
        externalEuint32 encCapFactor, bytes calldata cfProof
    ) external returns (uint256 wellId) {
        require(isDeveloper[msg.sender], "Not registered developer");
        wellId = wellCount++;
        GeothermalWell storage w = wells[wellId];
        w.wellId = wellId;
        w.wellName = wellName;
        w.fieldLocation = fieldLocation;
        w.steamQuality = steamQuality;
        w.status = WellStatus.Development;
        w.reservoirTempCelsius = FHE.fromExternal(encReservoirTemp, tempProof);
        w.installedCapacityKW = FHE.fromExternal(encCapacityKW, capProof);
        w.cumulativeMWhProduced = FHE.asEuint64(0);
        w.capacityFactorBps = FHE.fromExternal(encCapFactor, cfProof);
        w.steamPressureBarX10 = FHE.asEuint32(0);
        w.royaltyPaidUSD = FHE.asEuint64(0);
        w.developer = msg.sender;
        FHE.allowThis(w.reservoirTempCelsius); FHE.allow(w.reservoirTempCelsius, msg.sender);
        FHE.allowThis(w.installedCapacityKW); FHE.allow(w.installedCapacityKW, msg.sender);
        FHE.allowThis(w.cumulativeMWhProduced); FHE.allow(w.cumulativeMWhProduced, msg.sender);
        FHE.allowThis(w.capacityFactorBps); FHE.allowThis(w.royaltyPaidUSD);
        emit WellRegistered(wellId, wellName, steamQuality);
    }

    function recordProduction(
        uint256 wellId,
        externalEuint64 encGrossMWh, bytes calldata grossProof,
        externalEuint64 encOwnUseMWh, bytes calldata ownProof,
        externalEuint64 encRevenue, bytes calldata revProof,
        uint256 periodStart, uint256 periodEnd
    ) external nonReentrant {
        GeothermalWell storage w = wells[wellId];
        require(w.developer == msg.sender, "Not well developer");
        require(w.status == WellStatus.Production, "Not in production");

        euint64 grossMWh = FHE.fromExternal(encGrossMWh, grossProof);
        euint64 ownUseMWh = FHE.fromExternal(encOwnUseMWh, ownProof);
        euint64 revenue = FHE.fromExternal(encRevenue, revProof);
        euint64 netMWh = FHE.sub(grossMWh, ownUseMWh);

        // Compute royalty
        RoyaltyTerms storage terms = royaltyTerms[w.developer];
        ebool aboveTier = FHE.ge(netMWh, terms.tierThresholdMWh);
        euint32 appliedRate = FHE.select(aboveTier, terms.progressiveTierBps, terms.basRoyaltyRateBps);
        euint64 royalty = FHE.div(FHE.mul(revenue, FHE.asEuint64(appliedRate)), 10000);
        // Apply minimum
        ebool belowMin = FHE.lt(royalty, terms.minimumAnnualRoyalty);
        euint64 finalRoyalty = FHE.select(belowMin, terms.minimumAnnualRoyalty, royalty);

        uint256 recIdx = productionHistory[wellId].length;
        productionHistory[wellId].push(ProductionRecord({
            wellId: wellId,
            grossMWhProduced: grossMWh,
            ownUseMWh: ownUseMWh,
            netMWhExported: netMWh,
            revenueUSD: revenue,
            royaltyAmountUSD: finalRoyalty,
            periodStart: periodStart,
            periodEnd: periodEnd,
            audited: false
        }));

        w.cumulativeMWhProduced = FHE.add(w.cumulativeMWhProduced, netMWh);
        w.royaltyPaidUSD = FHE.add(w.royaltyPaidUSD, finalRoyalty);
        _totalMWhGenerated = FHE.add(_totalMWhGenerated, netMWh);
        _totalRoyaltiesCollected = FHE.add(_totalRoyaltiesCollected, finalRoyalty);
        _totalRevenueAcrossWells = FHE.add(_totalRevenueAcrossWells, revenue);

        FHE.allowThis(productionHistory[wellId][recIdx].grossMWhProduced);
        FHE.allowThis(productionHistory[wellId][recIdx].netMWhExported);
        FHE.allowThis(productionHistory[wellId][recIdx].revenueUSD);
        FHE.allow(productionHistory[wellId][recIdx].revenueUSD, w.developer);
        FHE.allowThis(productionHistory[wellId][recIdx].royaltyAmountUSD);
        FHE.allow(productionHistory[wellId][recIdx].royaltyAmountUSD, w.developer);
        FHE.allowThis(w.cumulativeMWhProduced); FHE.allowThis(w.royaltyPaidUSD);
        FHE.allowThis(_totalMWhGenerated); FHE.allowThis(_totalRoyaltiesCollected); FHE.allowThis(_totalRevenueAcrossWells);

        emit ProductionRecorded(wellId, recIdx);
        emit RoyaltyPaid(wellId, w.developer);
    }

    function updateWellStatus(uint256 wellId, WellStatus newStatus) external onlyGovernment {
        wells[wellId].status = newStatus;
        emit WellStatusChanged(wellId, newStatus);
    }

    function auditRecord(uint256 wellId, uint256 recordIdx) external onlyGovernment {
        productionHistory[wellId][recordIdx].audited = true;
    }

    function allowFieldStats(address viewer) external onlyOwner {
        FHE.allow(_totalMWhGenerated, viewer);
        FHE.allow(_totalRoyaltiesCollected, viewer);
        FHE.allow(_totalRevenueAcrossWells, viewer);
    }
}
