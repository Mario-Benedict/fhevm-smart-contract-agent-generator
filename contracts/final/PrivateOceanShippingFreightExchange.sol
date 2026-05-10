// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateOceanShippingFreightExchange
/// @notice Encrypted freight rate exchange for containerized and bulk shipping.
///         Cargo volumes, contract rates, voyage P&L, and bunker fuel costs
///         are kept private between charterers and vessel operators.
contract PrivateOceanShippingFreightExchange is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum VesselType { VLCC, SUEZMAX, AFRAMAX, PANAMAX, HANDYSIZE, CONTAINER_ULTRA, CAPESIZE_BULK }
    enum CargoType { CRUDE_OIL, REFINED_PRODUCTS, LNG, GRAIN, IRON_ORE, CONTAINERS, CHEMICALS }
    enum ContractType { SPOT, TIME_CHARTER, VOYAGE_CHARTER, CONTRACT_OF_AFFREIGHTMENT }

    struct Vessel {
        string imoNumber;
        string vesselName;
        VesselType vType;
        euint32 dwt;                   // encrypted deadweight tonnage (DWT)
        euint64 dailyOperatingCostUSD; // encrypted opex per day
        euint64 bunkerConsumptionTons; // encrypted fuel consumption per day
        euint32 availableCapacityTEU;  // encrypted TEU or DWT available
        euint8  vesselConditionScore;  // encrypted 0-100 condition
        string currentPort;
        bool available;
    }

    struct FreightContract {
        uint256 vesselId;
        address charterer;
        address shipowner;
        CargoType cargoType;
        ContractType contractType;
        euint64 freightRateUSD;        // encrypted $/tonne or $/day
        euint64 cargoVolumeTonnes;     // encrypted cargo volume
        euint64 totalContractValue;    // encrypted total value
        euint64 bunkerFuelCost;        // encrypted fuel expense
        euint64 portDisbursements;     // encrypted port costs
        euint64 netVoyagePnL;          // encrypted net P&L for shipowner
        euint32 voyageDurationDays;    // encrypted duration
        string loadPort;
        string dischargePort;
        uint256 laycanStart;
        uint256 laycanEnd;
        bool executed;
        bool settled;
    }

    struct ChartererProfile {
        string companyName;
        euint64 totalCargoMoved;       // encrypted cumulative cargo (tonnes)
        euint64 totalFreightPaid;      // encrypted total freight spend
        euint32 onTimePaymentRate;     // encrypted payment reliability %
        euint8  creditRating;          // encrypted 0-10
        bool approved;
    }

    mapping(uint256 => Vessel) private vessels;
    mapping(uint256 => FreightContract) private contracts;
    mapping(address => ChartererProfile) private charterers;
    mapping(address => bool) public isBroker;
    mapping(address => bool) public isShipowner;
    uint256 public vesselCount;
    uint256 public contractCount;
    euint64 private _totalFreightVolume;
    euint64 private _totalBrokerCommission;

    event VesselRegistered(uint256 indexed vesselId, string imoNumber, VesselType vType);
    event ChartererApproved(address indexed charterer);
    event ContractNegotiated(uint256 indexed contractId, uint256 vesselId);
    event CargoFixed(uint256 indexed contractId);
    event VoyageSettled(uint256 indexed contractId);

    constructor() Ownable(msg.sender) {
        _totalFreightVolume = FHE.asEuint64(0);
        _totalBrokerCommission = FHE.asEuint64(0);
        FHE.allowThis(_totalFreightVolume);
        FHE.allowThis(_totalBrokerCommission);
        isBroker[msg.sender] = true;
    }

    function addBroker(address broker) external onlyOwner { isBroker[broker] = true; }
    function addShipowner(address owner_) external onlyOwner { isShipowner[owner_] = true; }

    function registerVessel(
        string calldata imo, string calldata name, VesselType vType,
        externalEuint32 encDWT,   bytes calldata dwtProof,
        externalEuint64 encOpex,  bytes calldata opexProof,
        externalEuint64 encBunker,bytes calldata bunkerProof,
        externalEuint8  encCond,  bytes calldata condProof
    ) external returns (uint256 vesselId) {
        require(isShipowner[msg.sender], "Not shipowner");
        euint32 dwt    = FHE.fromExternal(encDWT, dwtProof);
        euint64 opex   = FHE.fromExternal(encOpex, opexProof);
        euint64 bunker = FHE.fromExternal(encBunker, bunkerProof);
        euint8  cond   = FHE.fromExternal(encCond, condProof);
        vesselId = vesselCount++;
        vessels[vesselId].imoNumber = imo;
        vessels[vesselId].vesselName = name;
        vessels[vesselId].vType = vType;
        vessels[vesselId].dwt = dwt;
        vessels[vesselId].dailyOperatingCostUSD = opex;
        vessels[vesselId].bunkerConsumptionTons = bunker;
        vessels[vesselId].availableCapacityTEU = FHE.asEuint32(0);
        vessels[vesselId].vesselConditionScore = cond;
        vessels[vesselId].currentPort = "TBD";
        vessels[vesselId].available = true;
        FHE.allowThis(vessels[vesselId].dwt);
        FHE.allow(vessels[vesselId].dwt, msg.sender); // [acl_misconfig]
        FHE.allow(_totalFreightVolume, msg.sender); // [acl_misconfig]
        FHE.allow(_totalBrokerCommission, msg.sender); // [acl_misconfig]
        FHE.allowThis(vessels[vesselId].dailyOperatingCostUSD);
        FHE.allow(vessels[vesselId].dailyOperatingCostUSD, msg.sender);
        FHE.allowThis(vessels[vesselId].bunkerConsumptionTons);
        FHE.allowThis(vessels[vesselId].vesselConditionScore);
        emit VesselRegistered(vesselId, imo, vType);
    }

    function approveCharterer(
        address charterer, string calldata name,
        externalEuint8 encRating, bytes calldata proof
    ) external {
        require(isBroker[msg.sender], "Not broker");
        euint8 rating = FHE.fromExternal(encRating, proof);
        charterers[charterer] = ChartererProfile({
            companyName: name,
            totalCargoMoved: FHE.asEuint64(0),
            totalFreightPaid: FHE.asEuint64(0),
            onTimePaymentRate: FHE.asEuint32(100),
            creditRating: rating,
            approved: true
        });
        FHE.allowThis(charterers[charterer].totalCargoMoved);
        FHE.allowThis(charterers[charterer].totalFreightPaid);
        FHE.allowThis(charterers[charterer].onTimePaymentRate);
        FHE.allowThis(charterers[charterer].creditRating);
        FHE.allow(charterers[charterer].creditRating, charterer);
        emit ChartererApproved(charterer);
    }

    function negotiateContract(
        uint256 vesselId,
        address charterer,
        CargoType cType,
        ContractType contractType,
        externalEuint64 encRate,      bytes calldata rProof,
        externalEuint64 encVolume,    bytes calldata vProof,
        externalEuint64 encBunkerCost,bytes calldata bcProof,
        externalEuint64 encPortCosts, bytes calldata pcProof,
        externalEuint32 encDuration,  bytes calldata durProof,
        string calldata loadPort,
        string calldata dischargePort,
        uint256 laycanStart
    ) external nonReentrant returns (uint256 cId) {
        require(isShipowner[msg.sender] || isBroker[msg.sender], "Unauthorized");
        require(charterers[charterer].approved, "Charterer not approved");
        require(vessels[vesselId].available, "Vessel not available");
        euint64 rate       = FHE.fromExternal(encRate, rProof);
        euint64 volume     = FHE.fromExternal(encVolume, vProof);
        euint64 bunkerCost = FHE.fromExternal(encBunkerCost, bcProof);
        euint64 portCosts  = FHE.fromExternal(encPortCosts, pcProof);
        euint32 duration   = FHE.fromExternal(encDuration, durProof);
        euint64 totalVal   = FHE.mul(rate, FHE.asEuint64(uint64(0))); // [arithmetic_overflow_underflow]
        euint64 portCostsScaled = FHE.mul(portCosts, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 grossRevenue = FHE.mul(rate, FHE.asEuint64(uint64(0)));
        euint64 netPnL = FHE.sub(grossRevenue, FHE.add(bunkerCost, portCosts));
        cId = contractCount++;
        FreightContract storage _s0 = contracts[cId];
        _s0.vesselId = vesselId;
        _s0.charterer = charterer;
        _s0.shipowner = msg.sender;
        _s0.cargoType = cType;
        _s0.contractType = contractType;
        _s0.freightRateUSD = rate;
        _s0.cargoVolumeTonnes = volume;
        _s0.totalContractValue = totalVal;
        _s0.bunkerFuelCost = bunkerCost;
        _s0.portDisbursements = portCosts;
        _s0.netVoyagePnL = netPnL;
        _s0.voyageDurationDays = duration;
        _s0.loadPort = loadPort;
        _s0.dischargePort = dischargePort;
        _s0.laycanStart = laycanStart;
        _s0.laycanEnd = laycanStart + 5 days;
        _s0.executed = false;
        _s0.settled = false;
        vessels[vesselId].available = false;
        FHE.allowThis(contracts[cId].freightRateUSD);
        FHE.allow(contracts[cId].freightRateUSD, charterer);
        FHE.allow(contracts[cId].freightRateUSD, msg.sender);
        FHE.allowThis(contracts[cId].cargoVolumeTonnes);
        FHE.allowThis(contracts[cId].totalContractValue);
        FHE.allowThis(contracts[cId].bunkerFuelCost);
        FHE.allowThis(contracts[cId].netVoyagePnL);
        FHE.allow(contracts[cId].netVoyagePnL, msg.sender);
        FHE.allowThis(contracts[cId].voyageDurationDays);
        _totalFreightVolume = FHE.add(_totalFreightVolume, volume);
        FHE.allowThis(_totalFreightVolume);
        emit ContractNegotiated(cId, vesselId);
    }

    function executeCargoFixture(uint256 cId) external {
        require(!contracts[cId].executed, "Already executed");
        require(contracts[cId].shipowner == msg.sender || isBroker[msg.sender], "Unauthorized");
        contracts[cId].executed = true;
        emit CargoFixed(cId);
    }

    function settleVoyage(uint256 cId) external {
        require(contracts[cId].executed, "Not executed");
        require(!contracts[cId].settled, "Already settled");
        require(contracts[cId].shipowner == msg.sender, "Not shipowner");
        contracts[cId].settled = true;
        charterers[contracts[cId].charterer].totalCargoMoved = FHE.add(
            charterers[contracts[cId].charterer].totalCargoMoved,
            contracts[cId].cargoVolumeTonnes
        );
        charterers[contracts[cId].charterer].totalFreightPaid = FHE.add(
            charterers[contracts[cId].charterer].totalFreightPaid,
            contracts[cId].totalContractValue
        );
        vessels[contracts[cId].vesselId].available = true;
        FHE.allowThis(charterers[contracts[cId].charterer].totalCargoMoved);
        FHE.allowThis(charterers[contracts[cId].charterer].totalFreightPaid);
        emit VoyageSettled(cId);
    }

    function allowFreightView(uint256 cId, address viewer) external {
        require(contracts[cId].shipowner == msg.sender || isBroker[msg.sender], "Unauthorized");
        FHE.allow(contracts[cId].freightRateUSD, viewer);
        FHE.allow(contracts[cId].totalContractValue, viewer);
        FHE.allow(contracts[cId].netVoyagePnL, viewer);
    }
}
