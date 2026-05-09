// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedDistrictHeatingNetworkBid
/// @notice District heating network capacity allocation with encrypted heat
///         demand forecasts, production cost curves, grid connection fees,
///         and confidential bilateral supply agreements.
contract EncryptedDistrictHeatingNetworkBid is ZamaEthereumConfig, AccessControl, ReentrancyGuard {

    bytes32 public constant GRID_OPERATOR_ROLE = keccak256("GRID_OPERATOR_ROLE");
    bytes32 public constant PRODUCER_ROLE = keccak256("PRODUCER_ROLE");
    bytes32 public constant CONSUMER_ROLE = keccak256("CONSUMER_ROLE");

    enum HeatSource { NATURAL_GAS_CHP, BIOMASS_CHP, GEOTHERMAL, INDUSTRIAL_WASTE_HEAT, HEAT_PUMP, SOLAR_THERMAL }
    enum ConnectionType { RESIDENTIAL, COMMERCIAL, INDUSTRIAL, ANCHOR_LOAD }
    enum SeasonType { WINTER_PEAK, SHOULDER, SUMMER }

    struct HeatProducer {
        HeatSource source;
        euint64 installedCapacityMW;     // encrypted installed capacity
        euint64 maxAnnualOutputMWh;      // encrypted max annual output
        euint64 variableCostPerMWh;      // encrypted variable cost
        euint64 fixedCostPerYear;        // encrypted annual fixed cost
        euint64 gridConnectionFee;       // encrypted grid connection fee paid
        euint64 currentOutputMW;         // encrypted current dispatch level
        euint64 revenueAccrued;          // encrypted total revenue earned
        euint64 carbonCreditEarned;      // encrypted carbon credits from heat
        bool dispatchable;
        bool active;
    }

    struct HeatConsumer {
        ConnectionType connectionType;
        euint64 peakDemandMW;            // encrypted peak heat demand
        euint64 annualConsumptionMWh;    // encrypted annual consumption
        euint64 currentDemandMW;         // encrypted real-time demand
        euint64 monthlyBill;             // encrypted current month bill
        euint64 priceCapPerMWh;          // encrypted contracted price cap
        euint64 totalBilledToDate;       // encrypted total billed amount
        euint64 demandResponseFlexibility;// encrypted DR flexibility (MW)
        bool interruptible;
        bool active;
    }

    struct DispatchSchedule {
        mapping(address => euint64) producerDispatch;  // encrypted dispatch per producer
        euint64 totalScheduledMW;        // encrypted total scheduled
        euint64 forecastDemandMW;        // encrypted forecasted demand
        euint64 balancingEnergyMW;       // encrypted balancing energy
        SeasonType season;
        uint256 scheduleDate;
        bool committed;
    }

    struct SupplyAgreement {
        address producer;
        address consumer;
        euint64 contractedCapacityMW;    // encrypted agreed capacity
        euint64 agreedPricePerMWh;       // encrypted agreed price
        euint64 deliveredMWh;            // encrypted delivered energy
        euint64 billedAmount;            // encrypted billed amount
        uint256 startDate;
        uint256 endDate;
        bool active;
    }

    mapping(address => HeatProducer) private producers;
    mapping(address => HeatConsumer) private consumers;
    mapping(uint256 => DispatchSchedule) private schedules;
    mapping(bytes32 => SupplyAgreement) private agreements;

    euint64 private _gridBalancingCostAccrued;   // encrypted grid balancing cost
    euint64 private _totalHeatDeliveredMWh;       // encrypted total energy delivered
    euint64 private _totalGridRevenue;            // encrypted total grid revenue
    euint64 private _systemMarginalPrice;         // encrypted system marginal price
    uint256 private _scheduleCount;

    event ProducerRegistered(address indexed producer, HeatSource source);
    event ConsumerRegistered(address indexed consumer, ConnectionType connType);
    event DispatchSchedulePublished(uint256 indexed scheduleId, SeasonType season);
    event SupplyAgreementCreated(bytes32 indexed agreementId);
    event DemandResponseActivated(address indexed consumer);
    event BillingCycleCompleted(uint256 timestamp);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GRID_OPERATOR_ROLE, msg.sender);
        _gridBalancingCostAccrued = FHE.asEuint64(0);
        _totalHeatDeliveredMWh = FHE.asEuint64(0);
        _totalGridRevenue = FHE.asEuint64(0);
        _systemMarginalPrice = FHE.asEuint64(0);
        FHE.allowThis(_gridBalancingCostAccrued);
        FHE.allowThis(_totalHeatDeliveredMWh);
        FHE.allowThis(_totalGridRevenue);
        FHE.allowThis(_systemMarginalPrice);
    }

    function registerProducer(
        HeatSource source,
        externalEuint64 encCapacityMW, bytes calldata capProof,
        externalEuint64 encMaxAnnualMWh, bytes calldata mawProof,
        externalEuint64 encVariableCost, bytes calldata vcProof,
        externalEuint64 encFixedCost, bytes calldata fcProof,
        externalEuint64 encConnectionFee, bytes calldata cfProof,
        bool dispatchable
    ) external onlyRole(GRID_OPERATOR_ROLE) {
        euint64 capacity = FHE.fromExternal(encCapacityMW, capProof);
        euint64 maxAnnual = FHE.fromExternal(encMaxAnnualMWh, mawProof);
        euint64 variableCost = FHE.fromExternal(encVariableCost, vcProof);
        euint64 fixedCost = FHE.fromExternal(encFixedCost, fcProof);
        euint64 connectionFee = FHE.fromExternal(encConnectionFee, cfProof);

        producers[msg.sender].source = source;
        producers[msg.sender].installedCapacityMW = capacity;
        producers[msg.sender].maxAnnualOutputMWh = maxAnnual;
        producers[msg.sender].variableCostPerMWh = variableCost;
        producers[msg.sender].fixedCostPerYear = fixedCost;
        producers[msg.sender].gridConnectionFee = connectionFee;
        producers[msg.sender].currentOutputMW = FHE.asEuint64(0);
        producers[msg.sender].revenueAccrued = FHE.asEuint64(0);
        producers[msg.sender].carbonCreditEarned = FHE.asEuint64(0);
        producers[msg.sender].dispatchable = dispatchable;
        producers[msg.sender].active = true;

        _grantRole(PRODUCER_ROLE, msg.sender);

        FHE.allowThis(capacity); FHE.allow(capacity, msg.sender);
        FHE.allowThis(maxAnnual); FHE.allow(maxAnnual, msg.sender);
        FHE.allowThis(variableCost); FHE.allow(variableCost, msg.sender);
        FHE.allowThis(fixedCost); FHE.allow(fixedCost, msg.sender);
        FHE.allowThis(connectionFee); FHE.allow(connectionFee, msg.sender);
        FHE.allowThis(producers[msg.sender].currentOutputMW);
        FHE.allow(producers[msg.sender].currentOutputMW, msg.sender);
        FHE.allowThis(producers[msg.sender].revenueAccrued);
        FHE.allow(producers[msg.sender].revenueAccrued, msg.sender);
        FHE.allowThis(producers[msg.sender].carbonCreditEarned);
        FHE.allow(producers[msg.sender].carbonCreditEarned, msg.sender);

        emit ProducerRegistered(msg.sender, source);
    }

    function registerConsumer(
        ConnectionType connectionType,
        externalEuint64 encPeakDemand, bytes calldata pdProof,
        externalEuint64 encAnnualConsumption, bytes calldata acProof,
        externalEuint64 encPriceCap, bytes calldata pcProof,
        externalEuint64 encDRFlexibility, bytes calldata drProof,
        bool interruptible
    ) external onlyRole(GRID_OPERATOR_ROLE) {
        euint64 peakDemand = FHE.fromExternal(encPeakDemand, pdProof);
        euint64 annualConsumption = FHE.fromExternal(encAnnualConsumption, acProof);
        euint64 priceCap = FHE.fromExternal(encPriceCap, pcProof);
        euint64 drFlexibility = FHE.fromExternal(encDRFlexibility, drProof);

        consumers[msg.sender].connectionType = connectionType;
        consumers[msg.sender].peakDemandMW = peakDemand;
        consumers[msg.sender].annualConsumptionMWh = annualConsumption;
        consumers[msg.sender].currentDemandMW = FHE.asEuint64(0);
        consumers[msg.sender].monthlyBill = FHE.asEuint64(0);
        consumers[msg.sender].priceCapPerMWh = priceCap;
        consumers[msg.sender].totalBilledToDate = FHE.asEuint64(0);
        consumers[msg.sender].demandResponseFlexibility = drFlexibility;
        consumers[msg.sender].interruptible = interruptible;
        consumers[msg.sender].active = true;

        _grantRole(CONSUMER_ROLE, msg.sender);

        FHE.allowThis(peakDemand); FHE.allow(peakDemand, msg.sender);
        FHE.allowThis(annualConsumption); FHE.allow(annualConsumption, msg.sender);
        FHE.allowThis(priceCap); FHE.allow(priceCap, msg.sender);
        FHE.allowThis(drFlexibility); FHE.allow(drFlexibility, msg.sender);
        FHE.allowThis(consumers[msg.sender].currentDemandMW);
        FHE.allowThis(consumers[msg.sender].monthlyBill);
        FHE.allow(consumers[msg.sender].monthlyBill, msg.sender);
        FHE.allowThis(consumers[msg.sender].totalBilledToDate);
        FHE.allow(consumers[msg.sender].totalBilledToDate, msg.sender);

        emit ConsumerRegistered(msg.sender, connectionType);
    }

    function createSupplyAgreement(
        address producer,
        address consumer,
        externalEuint64 encContractedCapacity, bytes calldata ccProof,
        externalEuint64 encAgreedPrice, bytes calldata apProof,
        uint256 startDate,
        uint256 endDate
    ) external onlyRole(GRID_OPERATOR_ROLE) returns (bytes32 agreementId) {
        require(producers[producer].active, "Producer not active");
        require(consumers[consumer].active, "Consumer not active");

        euint64 contractedCapacity = FHE.fromExternal(encContractedCapacity, ccProof);
        euint64 agreedPrice = FHE.fromExternal(encAgreedPrice, apProof);

        // Verify price is within consumer's cap
        ebool withinCap = FHE.le(agreedPrice, consumers[consumer].priceCapPerMWh);
        euint64 effectivePrice = FHE.select(withinCap, agreedPrice, consumers[consumer].priceCapPerMWh);

        agreementId = keccak256(abi.encodePacked(producer, consumer, startDate, block.timestamp));

        agreements[agreementId].producer = producer;
        agreements[agreementId].consumer = consumer;
        agreements[agreementId].contractedCapacityMW = contractedCapacity;
        agreements[agreementId].agreedPricePerMWh = effectivePrice;
        agreements[agreementId].deliveredMWh = FHE.asEuint64(0);
        agreements[agreementId].billedAmount = FHE.asEuint64(0);
        agreements[agreementId].startDate = startDate;
        agreements[agreementId].endDate = endDate;
        agreements[agreementId].active = true;

        FHE.allowThis(contractedCapacity);
        FHE.allow(contractedCapacity, producer);
        FHE.allow(contractedCapacity, consumer);
        FHE.allowThis(effectivePrice);
        FHE.allow(effectivePrice, producer);
        FHE.allow(effectivePrice, consumer);
        FHE.allowThis(agreements[agreementId].deliveredMWh);
        FHE.allow(agreements[agreementId].deliveredMWh, producer);
        FHE.allow(agreements[agreementId].deliveredMWh, consumer);
        FHE.allowThis(agreements[agreementId].billedAmount);
        FHE.allow(agreements[agreementId].billedAmount, producer);
        FHE.allow(agreements[agreementId].billedAmount, consumer);

        emit SupplyAgreementCreated(agreementId);
    }

    function recordHeatDelivery(
        bytes32 agreementId,
        externalEuint64 encDeliveredMWh, bytes calldata dmwhProof
    ) external onlyRole(GRID_OPERATOR_ROLE) {
        SupplyAgreement storage agr = agreements[agreementId];
        require(agr.active, "Agreement not active");
        euint64 deliveredMWh = FHE.fromExternal(encDeliveredMWh, dmwhProof);
        agr.deliveredMWh = FHE.add(agr.deliveredMWh, deliveredMWh);
        euint64 billingAmount = FHE.mul(deliveredMWh, agr.agreedPricePerMWh);
        agr.billedAmount = FHE.add(agr.billedAmount, billingAmount);
        consumers[agr.consumer].monthlyBill = FHE.add(consumers[agr.consumer].monthlyBill, billingAmount);
        consumers[agr.consumer].totalBilledToDate = FHE.add(consumers[agr.consumer].totalBilledToDate, billingAmount);
        producers[agr.producer].revenueAccrued = FHE.add(producers[agr.producer].revenueAccrued, billingAmount);
        _totalHeatDeliveredMWh = FHE.add(_totalHeatDeliveredMWh, deliveredMWh);
        _totalGridRevenue = FHE.add(_totalGridRevenue, billingAmount);
        FHE.allowThis(agr.deliveredMWh);
        FHE.allow(agr.deliveredMWh, agr.producer);
        FHE.allow(agr.deliveredMWh, agr.consumer);
        FHE.allowThis(agr.billedAmount);
        FHE.allow(agr.billedAmount, agr.consumer);
        FHE.allowThis(consumers[agr.consumer].monthlyBill);
        FHE.allow(consumers[agr.consumer].monthlyBill, agr.consumer);
        FHE.allowThis(consumers[agr.consumer].totalBilledToDate);
        FHE.allow(consumers[agr.consumer].totalBilledToDate, agr.consumer);
        FHE.allowThis(producers[agr.producer].revenueAccrued);
        FHE.allow(producers[agr.producer].revenueAccrued, agr.producer);
        FHE.allowThis(_totalHeatDeliveredMWh);
        FHE.allowThis(_totalGridRevenue);
    }

    function allowGridStatsView(address viewer) external onlyRole(GRID_OPERATOR_ROLE) {
        FHE.allow(_totalHeatDeliveredMWh, viewer);
        FHE.allow(_totalGridRevenue, viewer);
        FHE.allow(_systemMarginalPrice, viewer);
        FHE.allow(_gridBalancingCostAccrued, viewer);
    }
}
