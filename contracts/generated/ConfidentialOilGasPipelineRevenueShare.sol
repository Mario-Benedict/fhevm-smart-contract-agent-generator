// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialOilGasPipelineRevenueShare
/// @notice Midstream pipeline revenue sharing with encrypted throughput volumes,
///         tariff rates, shipper allocations, and capacity reservation fees.
contract ConfidentialOilGasPipelineRevenueShare is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CommodityGrade { CRUDE_LIGHT, CRUDE_HEAVY, NATURAL_GAS, NGL, CONDENSATE, REFINED }
    enum ShipperClass { ANCHOR, COMMITTED, SPOT, INTERRUPTIBLE }

    struct PipelineSegment {
        string segmentName;
        string originPoint;
        string destinationPoint;
        euint64 capacityBOED;         // encrypted barrels of oil equivalent per day
        euint64 currentThroughput;    // encrypted current flow
        euint64 tariffRateUSDPerBBL;  // encrypted tariff per barrel
        euint64 revenueYTD;           // encrypted year-to-date revenue
        euint32 lengthKm;             // encrypted segment length
        euint8  utilizationPct;       // encrypted capacity utilization
        bool operational;
    }

    struct ShipperAgreement {
        address shipper;
        uint256 segmentId;
        ShipperClass shipperClass;
        CommodityGrade commodity;
        euint64 reservedCapacityBOED; // encrypted reserved capacity
        euint64 minimumVolumeBBL;     // encrypted minimum commitment
        euint64 actualVolumeShipped;  // encrypted actual shipped
        euint64 totalTariffPaid;      // encrypted cumulative tariffs
        euint64 deficiencyPaymentDue; // encrypted take-or-pay deficiency
        euint32 contractDurationDays; // encrypted term
        uint256 startDate;
        bool active;
    }

    struct RevenueDistribution {
        uint256 periodEnd;
        euint64 grossRevenue;         // encrypted total tariff collected
        euint64 operatingCosts;       // encrypted opex
        euint64 netRevenue;           // encrypted distributable income
        euint64 maintenanceReserve;   // encrypted capex reserve
        bool distributed;
    }

    mapping(uint256 => PipelineSegment) private segments;
    mapping(uint256 => ShipperAgreement) private agreements;
    mapping(uint256 => RevenueDistribution) private distributions;
    mapping(address => bool) public isPipelineOperator;
    mapping(address => bool) public isRegulator;
    uint256 public segmentCount;
    uint256 public agreementCount;
    uint256 public distributionCount;
    euint64 private _totalSystemThroughput;
    euint64 private _totalRevenueAllTime;
    euint64 private _totalOperatingCosts;

    event SegmentRegistered(uint256 indexed segId, string name);
    event ShipperAgreementSigned(uint256 indexed agrId, address shipper);
    event ThroughputRecorded(uint256 indexed segId);
    event RevenueDistributed(uint256 indexed distId);
    event DeficiencyCharged(uint256 indexed agrId);

    constructor() Ownable(msg.sender) {
        _totalSystemThroughput = FHE.asEuint64(0);
        _totalRevenueAllTime   = FHE.asEuint64(0);
        _totalOperatingCosts   = FHE.asEuint64(0);
        FHE.allowThis(_totalSystemThroughput);
        FHE.allowThis(_totalRevenueAllTime);
        FHE.allowThis(_totalOperatingCosts);
        isPipelineOperator[msg.sender] = true;
    }

    modifier onlyOperator() { require(isPipelineOperator[msg.sender], "Not operator"); _; }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addOperator(address op) external onlyOwner { isPipelineOperator[op] = true; }
    function addRegulator(address reg) external onlyOwner { isRegulator[reg] = true; }

    function registerSegment(
        string calldata name,
        string calldata origin,
        string calldata destination,
        externalEuint64 encCapacity,  bytes calldata capProof,
        externalEuint64 encTariff,    bytes calldata tarProof,
        externalEuint32 encLength,    bytes calldata lenProof
    ) external onlyOperator whenNotPaused returns (uint256 segId) {
        euint64 capacity = FHE.fromExternal(encCapacity, capProof);
        euint64 tariff   = FHE.fromExternal(encTariff,   tarProof);
        euint32 length   = FHE.fromExternal(encLength,   lenProof);

        segId = segmentCount++;
        segments[segId] = PipelineSegment({
            segmentName: name, originPoint: origin, destinationPoint: destination,
            capacityBOED: capacity, currentThroughput: FHE.asEuint64(0),
            tariffRateUSDPerBBL: tariff, revenueYTD: FHE.asEuint64(0),
            lengthKm: length, utilizationPct: FHE.asEuint8(0),
            operational: true
        });
        FHE.allowThis(segments[segId].capacityBOED);
        FHE.allow(segments[segId].capacityBOED, msg.sender);
        FHE.allowThis(segments[segId].currentThroughput);
        FHE.allowThis(segments[segId].tariffRateUSDPerBBL);
        FHE.allow(segments[segId].tariffRateUSDPerBBL, msg.sender);
        FHE.allowThis(segments[segId].revenueYTD);
        FHE.allow(segments[segId].revenueYTD, msg.sender);
        FHE.allowThis(segments[segId].lengthKm);
        FHE.allowThis(segments[segId].utilizationPct);
        emit SegmentRegistered(segId, name);
    }

    function signShipperAgreement(
        address shipper,
        uint256 segId,
        ShipperClass sClass,
        CommodityGrade commodity,
        externalEuint64 encReserved,  bytes calldata resProof,
        externalEuint64 encMinVol,    bytes calldata mvProof,
        externalEuint32 encDuration,  bytes calldata durProof
    ) external onlyOperator returns (uint256 agrId) {
        euint64 reserved = FHE.fromExternal(encReserved, resProof);
        euint64 minVol   = FHE.fromExternal(encMinVol,   mvProof);
        euint32 duration = FHE.fromExternal(encDuration, durProof);

        agrId = agreementCount++;
        agreements[agrId] = ShipperAgreement({
            shipper: shipper, segmentId: segId,
            shipperClass: sClass, commodity: commodity,
            reservedCapacityBOED: reserved, minimumVolumeBBL: minVol,
            actualVolumeShipped: FHE.asEuint64(0),
            totalTariffPaid: FHE.asEuint64(0),
            deficiencyPaymentDue: FHE.asEuint64(0),
            contractDurationDays: duration,
            startDate: block.timestamp, active: true
        });
        FHE.allowThis(agreements[agrId].reservedCapacityBOED);
        FHE.allow(agreements[agrId].reservedCapacityBOED, shipper);
        FHE.allowThis(agreements[agrId].minimumVolumeBBL);
        FHE.allow(agreements[agrId].minimumVolumeBBL, shipper);
        FHE.allowThis(agreements[agrId].actualVolumeShipped);
        FHE.allow(agreements[agrId].actualVolumeShipped, shipper);
        FHE.allowThis(agreements[agrId].totalTariffPaid);
        FHE.allow(agreements[agrId].totalTariffPaid, shipper);
        FHE.allowThis(agreements[agrId].deficiencyPaymentDue);
        FHE.allow(agreements[agrId].deficiencyPaymentDue, shipper);
        FHE.allowThis(agreements[agrId].contractDurationDays);
        emit ShipperAgreementSigned(agrId, shipper);
    }

    function recordMonthlyThroughput(
        uint256 agrId,
        externalEuint64 encVolume, bytes calldata proof
    ) external nonReentrant whenNotPaused {
        require(isPipelineOperator[msg.sender] ||
                agreements[agrId].shipper == msg.sender, "Unauthorized");
        require(agreements[agrId].active, "Agreement inactive");

        euint64 volume = FHE.fromExternal(encVolume, proof);
        uint256 segId  = agreements[agrId].segmentId;

        // Calculate tariff due
        euint64 tariffDue = FHE.mul(volume, segments[segId].tariffRateUSDPerBBL);

        // Update agreement
        agreements[agrId].actualVolumeShipped = FHE.add(
            agreements[agrId].actualVolumeShipped, volume
        );
        agreements[agrId].totalTariffPaid = FHE.add(
            agreements[agrId].totalTariffPaid, tariffDue
        );

        // Update segment metrics
        segments[segId].currentThroughput = FHE.add(
            segments[segId].currentThroughput, volume
        );
        segments[segId].revenueYTD = FHE.add(
            segments[segId].revenueYTD, tariffDue
        );

        _totalSystemThroughput = FHE.add(_totalSystemThroughput, volume);
        _totalRevenueAllTime   = FHE.add(_totalRevenueAllTime, tariffDue);

        // Check take-or-pay deficiency
        ebool belowMinimum = FHE.lt(
            agreements[agrId].actualVolumeShipped,
            agreements[agrId].minimumVolumeBBL
        );
        euint64 deficiency = FHE.select(
            belowMinimum,
            FHE.mul(
                FHE.sub(agreements[agrId].minimumVolumeBBL,
                        agreements[agrId].actualVolumeShipped),
                segments[segId].tariffRateUSDPerBBL
            ),
            FHE.asEuint64(0)
        );
        agreements[agrId].deficiencyPaymentDue = deficiency;

        FHE.allowThis(agreements[agrId].actualVolumeShipped);
        FHE.allow(agreements[agrId].actualVolumeShipped, agreements[agrId].shipper);
        FHE.allowThis(agreements[agrId].totalTariffPaid);
        FHE.allow(agreements[agrId].totalTariffPaid, agreements[agrId].shipper);
        FHE.allowThis(agreements[agrId].deficiencyPaymentDue);
        FHE.allow(agreements[agrId].deficiencyPaymentDue, agreements[agrId].shipper);
        FHE.allowThis(segments[segId].currentThroughput);
        FHE.allowThis(segments[segId].revenueYTD);
        FHE.allowThis(_totalSystemThroughput);
        FHE.allowThis(_totalRevenueAllTime);

        emit ThroughputRecorded(segId);
        if (FHE.isInitialized(belowMinimum)) emit DeficiencyCharged(agrId);
    }

    function distributeRevenue(
        uint256 segId,
        externalEuint64 encOpex,      bytes calldata opexProof,
        externalEuint64 encMaintRes,  bytes calldata mrProof
    ) external onlyOperator nonReentrant returns (uint256 distId) {
        euint64 opex    = FHE.fromExternal(encOpex,    opexProof);
        euint64 maintRes= FHE.fromExternal(encMaintRes, mrProof);

        euint64 gross   = segments[segId].revenueYTD;
        euint64 net     = FHE.sub(gross, FHE.add(opex, maintRes));

        distId = distributionCount++;
        distributions[distId] = RevenueDistribution({
            periodEnd: block.timestamp,
            grossRevenue: gross,
            operatingCosts: opex,
            netRevenue: net,
            maintenanceReserve: maintRes,
            distributed: true
        });
        _totalOperatingCosts = FHE.add(_totalOperatingCosts, opex);

        // Reset segment revenue after distribution
        segments[segId].revenueYTD = FHE.asEuint64(0);

        FHE.allowThis(distributions[distId].grossRevenue);
        FHE.allow(distributions[distId].grossRevenue, msg.sender);
        FHE.allowThis(distributions[distId].netRevenue);
        FHE.allow(distributions[distId].netRevenue, msg.sender);
        FHE.allowThis(distributions[distId].operatingCosts);
        FHE.allowThis(distributions[distId].maintenanceReserve);
        FHE.allowThis(segments[segId].revenueYTD);
        FHE.allowThis(_totalOperatingCosts);

        emit RevenueDistributed(distId);
    }

    function allowSystemView(address viewer) external onlyOwner {
        FHE.allow(_totalSystemThroughput, viewer);
        FHE.allow(_totalRevenueAllTime, viewer);
        FHE.allow(_totalOperatingCosts, viewer);
    }
}
