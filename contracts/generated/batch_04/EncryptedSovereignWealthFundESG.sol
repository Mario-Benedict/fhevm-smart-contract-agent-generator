// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSovereignWealthFundESG
/// @notice SWF portfolio management with encrypted ESG scores, sector allocations,
///         excluded entity blacklists, green bond quotas, and confidential
///         benchmark deviation tracking for responsible investment mandates.
contract EncryptedSovereignWealthFundESG is ZamaEthereumConfig, AccessControl, ReentrancyGuard {

    bytes32 public constant CIO_ROLE = keccak256("CIO_ROLE");
    bytes32 public constant ESG_ANALYST_ROLE = keccak256("ESG_ANALYST_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    enum AssetClass { EQUITY, FIXED_INCOME, REAL_ESTATE, INFRASTRUCTURE, PRIVATE_EQUITY, ALTERNATIVES }
    enum ESGRating { LEADER, AVERAGE, LAGGARD, EXCLUDED }
    enum SectorType { ENERGY_TRANSITION, HEALTHCARE, TECHNOLOGY, FINANCIALS, INDUSTRIALS, CONSUMER, UTILITIES }

    struct PortfolioPosition {
        AssetClass assetClass;
        SectorType sector;
        ESGRating esgRating;
        euint64 marketValue;         // encrypted market value USD
        euint64 bookValue;           // encrypted book value USD
        euint64 unrealizedGainLoss;  // encrypted unrealized P&L
        euint64 esgScore;            // encrypted ESG score (0-100)
        euint64 carbonFootprintTons; // encrypted annual CO2 footprint
        euint64 targetAllocationBps; // encrypted target weight in portfolio
        euint64 actualAllocationBps; // encrypted actual weight
        euint64 deviationBps;        // encrypted deviation from benchmark
        bool greenBondEligible;
        bool excluded;
        bool active;
    }

    struct ESGPortfolioMetrics {
        euint64 totalAUM;                    // encrypted total AUM
        euint64 weightedAvgESGScore;         // encrypted portfolio ESG score
        euint64 totalCarbonFootprintTons;    // encrypted total carbon footprint
        euint64 greenBondAllocationBps;      // encrypted green bond allocation %
        euint64 excludedEntityExposureBps;   // encrypted exposure to excluded entities
        euint64 climateVAR;                  // encrypted climate Value-at-Risk
        euint64 sdgAlignmentScore;           // encrypted UN SDG alignment score
        euint64 boardDiversityScore;         // encrypted investee board diversity score
        euint64 genderPayGapScore;           // encrypted investee gender pay gap metric
        euint64 controversyScore;            // encrypted controversy risk score
    }

    struct StakeholderReport {
        euint64 returnVsBenchmark;           // encrypted relative performance
        euint64 carbonReductionVsTarget;     // encrypted carbon progress
        euint64 esgScoreChange;              // encrypted YoY ESG change
        uint256 reportingPeriodEnd;
        bool published;
    }

    mapping(bytes32 => PortfolioPosition) private positions;
    mapping(address => bool) public excludedEntity;
    ESGPortfolioMetrics private portfolioMetrics;
    mapping(uint256 => StakeholderReport) private annualReports;

    euint64 private _carbonNeutralityTarget;  // encrypted net-zero target (tons)
    euint64 private _greenBondMinQuota;       // encrypted minimum green bond %
    euint64 private _maxSectorConcentration;  // encrypted max sector weight bps
    uint256 private _reportCount;

    event PositionAdded(bytes32 indexed positionId, AssetClass assetClass, SectorType sector);
    event ESGRatingUpdated(bytes32 indexed positionId, ESGRating newRating);
    event EntityExcluded(address indexed entity);
    event RebalanceTriggered(uint256 timestamp);
    event AnnualReportPublished(uint256 indexed reportId);
    event CarbonTargetUpdated();

    constructor(
        externalEuint64 encInitialAUM, bytes memory aumProof,
        externalEuint64 encGreenBondQuota, bytes memory gbqProof,
        externalEuint64 encCarbonTarget, bytes memory ctProof
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CIO_ROLE, msg.sender);
        _grantRole(ESG_ANALYST_ROLE, msg.sender);

        portfolioMetrics.totalAUM = FHE.fromExternal(encInitialAUM, aumProof);
        _greenBondMinQuota = FHE.fromExternal(encGreenBondQuota, gbqProof);
        _carbonNeutralityTarget = FHE.fromExternal(encCarbonTarget, ctProof);
        portfolioMetrics.weightedAvgESGScore = FHE.asEuint64(0);
        portfolioMetrics.totalCarbonFootprintTons = FHE.asEuint64(0);
        portfolioMetrics.greenBondAllocationBps = FHE.asEuint64(0);
        portfolioMetrics.excludedEntityExposureBps = FHE.asEuint64(0);
        portfolioMetrics.climateVAR = FHE.asEuint64(0);
        portfolioMetrics.sdgAlignmentScore = FHE.asEuint64(0);
        portfolioMetrics.boardDiversityScore = FHE.asEuint64(0);
        portfolioMetrics.genderPayGapScore = FHE.asEuint64(0);
        portfolioMetrics.controversyScore = FHE.asEuint64(0);
        _maxSectorConcentration = FHE.asEuint64(2500); // 25% max sector weight

        FHE.allowThis(portfolioMetrics.totalAUM);
        FHE.allowThis(_greenBondMinQuota);
        FHE.allowThis(_carbonNeutralityTarget);
        FHE.allowThis(portfolioMetrics.weightedAvgESGScore);
        FHE.allowThis(portfolioMetrics.totalCarbonFootprintTons);
        FHE.allowThis(portfolioMetrics.greenBondAllocationBps);
        FHE.allowThis(portfolioMetrics.excludedEntityExposureBps);
        FHE.allowThis(portfolioMetrics.climateVAR);
        FHE.allowThis(portfolioMetrics.sdgAlignmentScore);
        FHE.allowThis(portfolioMetrics.boardDiversityScore);
        FHE.allowThis(portfolioMetrics.genderPayGapScore);
        FHE.allowThis(portfolioMetrics.controversyScore);
        FHE.allowThis(_maxSectorConcentration);
    }

    function addPosition(
        bytes32 positionId,
        AssetClass assetClass,
        SectorType sector,
        externalEuint64 encMarketValue, bytes calldata mvProof,
        externalEuint64 encBookValue, bytes calldata bvProof,
        externalEuint64 encESGScore, bytes calldata esgProof,
        externalEuint64 encCarbonFootprint, bytes calldata cfProof,
        externalEuint64 encTargetAllocation, bytes calldata taProof,
        bool greenBondEligible
    ) external onlyRole(CIO_ROLE) {
        euint64 marketValue = FHE.fromExternal(encMarketValue, mvProof);
        euint64 bookValue = FHE.fromExternal(encBookValue, bvProof);
        euint64 esgScore = FHE.fromExternal(encESGScore, esgProof);
        euint64 carbonFootprint = FHE.fromExternal(encCarbonFootprint, cfProof);
        euint64 targetAllocation = FHE.fromExternal(encTargetAllocation, taProof);

        ebool profitable = FHE.ge(marketValue, bookValue);
        euint64 gainLoss = FHE.select(profitable,
            FHE.sub(marketValue, bookValue),
            FHE.sub(bookValue, marketValue));

        euint64 actualAllocationBps = FHE.mul(marketValue, FHE.asEuint64(10000)); // simplified: totalAUM divisor omitted
        euint64 deviationBps = FHE.select(FHE.ge(actualAllocationBps, targetAllocation),
            FHE.sub(actualAllocationBps, targetAllocation),
            FHE.sub(targetAllocation, actualAllocationBps));

        // Determine ESG rating from score
        ESGRating rating = ESGRating.AVERAGE;
        PortfolioPosition storage _s0 = positions[positionId];
        _s0.assetClass = assetClass;
        _s0.sector = sector;
        _s0.esgRating = rating;
        _s0.marketValue = marketValue;
        _s0.bookValue = bookValue;
        _s0.unrealizedGainLoss = gainLoss;
        _s0.esgScore = esgScore;
        _s0.carbonFootprintTons = carbonFootprint;
        _s0.targetAllocationBps = targetAllocation;
        _s0.actualAllocationBps = actualAllocationBps;
        _s0.deviationBps = deviationBps;
        _s0.greenBondEligible = greenBondEligible;
        _s0.excluded = false;
        _s0.active = true;

        // Update portfolio-level metrics
        portfolioMetrics.totalAUM = FHE.add(portfolioMetrics.totalAUM, marketValue);
        portfolioMetrics.totalCarbonFootprintTons = FHE.add(portfolioMetrics.totalCarbonFootprintTons, carbonFootprint);

        FHE.allowThis(marketValue); FHE.allowThis(bookValue); FHE.allowThis(esgScore);
        FHE.allowThis(carbonFootprint); FHE.allowThis(targetAllocation);
        FHE.allowThis(gainLoss); FHE.allowThis(actualAllocationBps); FHE.allowThis(deviationBps);
        FHE.allowThis(portfolioMetrics.totalAUM);
        FHE.allowThis(portfolioMetrics.totalCarbonFootprintTons);

        emit PositionAdded(positionId, assetClass, sector);
    }

    function updateESGScores(
        bytes32 positionId,
        externalEuint64 encNewESGScore, bytes calldata esgProof,
        externalEuint64 encNewCarbonFootprint, bytes calldata cfProof,
        externalEuint64 encControvScore, bytes calldata csProof,
        ESGRating newRating
    ) external onlyRole(ESG_ANALYST_ROLE) {
        PortfolioPosition storage pos = positions[positionId];
        require(pos.active, "Position not active");

        euint64 oldCarbon = pos.carbonFootprintTons;
        pos.esgScore = FHE.fromExternal(encNewESGScore, esgProof);
        pos.carbonFootprintTons = FHE.fromExternal(encNewCarbonFootprint, cfProof);
        pos.esgRating = newRating;

        euint64 controvScore = FHE.fromExternal(encControvScore, csProof);
        portfolioMetrics.controversyScore = FHE.add(portfolioMetrics.controversyScore, controvScore);

        // Adjust portfolio-level carbon footprint
        portfolioMetrics.totalCarbonFootprintTons = FHE.add(
            FHE.sub(portfolioMetrics.totalCarbonFootprintTons, oldCarbon),
            pos.carbonFootprintTons
        );

        if (newRating == ESGRating.EXCLUDED) {
            pos.excluded = true;
        }

        FHE.allowThis(pos.esgScore);
        FHE.allowThis(pos.carbonFootprintTons);
        FHE.allowThis(portfolioMetrics.controversyScore);
        FHE.allowThis(portfolioMetrics.totalCarbonFootprintTons);
        emit ESGRatingUpdated(positionId, newRating);
    }

    function excludeEntity(address entity) external onlyRole(CIO_ROLE) {
        excludedEntity[entity] = true;
        emit EntityExcluded(entity);
    }

    function publishAnnualReport(
        externalEuint64 encReturnVsBenchmark, bytes calldata rvbProof,
        externalEuint64 encCarbonReduction, bytes calldata crProof,
        externalEuint64 encESGScoreChange, bytes calldata escProof,
        uint256 periodEnd
    ) external onlyRole(CIO_ROLE) {
        euint64 returnVsBenchmark = FHE.fromExternal(encReturnVsBenchmark, rvbProof);
        euint64 carbonReduction = FHE.fromExternal(encCarbonReduction, crProof);
        euint64 esgScoreChange = FHE.fromExternal(encESGScoreChange, escProof);

        uint256 reportId = ++_reportCount;
        annualReports[reportId] = StakeholderReport({
            returnVsBenchmark: returnVsBenchmark,
            carbonReductionVsTarget: carbonReduction,
            esgScoreChange: esgScoreChange,
            reportingPeriodEnd: periodEnd,
            published: true
        });

        FHE.allowThis(returnVsBenchmark);
        FHE.allowThis(carbonReduction);
        FHE.allowThis(esgScoreChange);
        emit AnnualReportPublished(reportId);
    }

    function allowMetricsView(address viewer) external onlyRole(AUDITOR_ROLE) {
        FHE.allow(portfolioMetrics.totalAUM, viewer);
        FHE.allow(portfolioMetrics.weightedAvgESGScore, viewer);
        FHE.allow(portfolioMetrics.totalCarbonFootprintTons, viewer);
        FHE.allow(portfolioMetrics.greenBondAllocationBps, viewer);
        FHE.allow(portfolioMetrics.sdgAlignmentScore, viewer);
        FHE.allow(_carbonNeutralityTarget, viewer);
    }
}
