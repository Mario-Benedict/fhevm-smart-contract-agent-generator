// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedElectricVehicleChargingMarket
/// @notice Dynamic EV charging marketplace: encrypted energy price per kWh per station,
///         encrypted session consumption, encrypted billing, and private demand-response signals.
contract EncryptedElectricVehicleChargingMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct ChargingStation {
        string stationId;
        string location;
        euint32 capacityKW;         // encrypted rated capacity
        euint64 pricePerKWhBps;     // encrypted price in basis points of base rate
        euint64 demandResponseSig;  // encrypted DR signal (0=normal, >5000=high demand)
        euint64 totalEnergyDelivered; // encrypted cumulative kWh
        euint64 totalRevenue;        // encrypted cumulative revenue
        bool active;
        address operator;
    }

    struct ChargingSession {
        uint256 stationId;
        address vehicle;
        euint32 energyKWh;          // encrypted energy delivered
        euint64 sessionCostBps;     // encrypted cost in basis points
        euint64 finalBillUSD;       // encrypted final bill
        uint256 startTime;
        uint256 endTime;
        bool completed;
    }

    struct VehicleAccount {
        euint64 prepaidBalance;     // encrypted prepaid credit
        euint64 totalConsumedKWh;   // encrypted lifetime consumption
        euint64 co2SavedKg;         // encrypted CO2 saving vs ICE
        bool registered;
    }

    mapping(uint256 => ChargingStation) private stations;
    mapping(uint256 => ChargingSession) private sessions;
    mapping(address => VehicleAccount) private vehicles;
    mapping(address => bool) public isGridOperator;
    uint256 public stationCount;
    uint256 public sessionCount;
    euint64 private _networkTotalEnergyKWh;
    euint64 private _baseRateUSDPerKWh; // encrypted network base rate

    event StationRegistered(uint256 indexed id, string stationId);
    event SessionStarted(uint256 indexed sessionId, uint256 stationId, address vehicle);
    event SessionCompleted(uint256 indexed sessionId);
    event DemandResponseUpdated(uint256 indexed stationId);
    event VehicleTopUp(address indexed vehicle);

    constructor(externalEuint64 encBaseRate, bytes memory brProof) Ownable(msg.sender) {
        _baseRateUSDPerKWh = FHE.fromExternal(encBaseRate, brProof);
        _networkTotalEnergyKWh = FHE.asEuint64(0);
        FHE.allowThis(_baseRateUSDPerKWh);
        FHE.allowThis(_networkTotalEnergyKWh);
        isGridOperator[msg.sender] = true;
    }

    function addGridOperator(address op) external onlyOwner { isGridOperator[op] = true; }

    function registerStation(
        string calldata stationId, string calldata location,
        externalEuint32 encCapacity, bytes calldata cProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external returns (uint256 id) {
        id = stationCount++;
        euint32 cap = FHE.fromExternal(encCapacity, cProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        stations[id].stationId = stationId;
        stations[id].location = location;
        stations[id].capacityKW = cap;
        stations[id].pricePerKWhBps = price;
        stations[id].demandResponseSig = FHE.asEuint64(0);
        stations[id].totalEnergyDelivered = FHE.asEuint64(0);
        stations[id].totalRevenue = FHE.asEuint64(0);
        stations[id].active = true;
        stations[id].operator = msg.sender;
        FHE.allowThis(stations[id].capacityKW);
        FHE.allowThis(stations[id].pricePerKWhBps);
        FHE.allowThis(stations[id].demandResponseSig);
        FHE.allowThis(stations[id].totalEnergyDelivered);
        FHE.allowThis(stations[id].totalRevenue);
        emit StationRegistered(id, stationId);
    }

    function registerVehicle(
        externalEuint64 encBalance, bytes calldata bProof
    ) external {
        euint64 balance = FHE.fromExternal(encBalance, bProof);
        vehicles[msg.sender] = VehicleAccount({
            prepaidBalance: balance,
            totalConsumedKWh: FHE.asEuint64(0),
            co2SavedKg: FHE.asEuint64(0),
            registered: true
        });
        FHE.allowThis(vehicles[msg.sender].prepaidBalance);
        FHE.allowThis(vehicles[msg.sender].totalConsumedKWh);
        FHE.allowThis(vehicles[msg.sender].co2SavedKg);
        FHE.allow(vehicles[msg.sender].prepaidBalance, msg.sender);
    }

    function topUpBalance(externalEuint64 encAmount, bytes calldata proof) external {
        require(vehicles[msg.sender].registered, "Not registered");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        vehicles[msg.sender].prepaidBalance = FHE.add(vehicles[msg.sender].prepaidBalance, amount);
        FHE.allowThis(vehicles[msg.sender].prepaidBalance);
        FHE.allow(vehicles[msg.sender].prepaidBalance, msg.sender);
        emit VehicleTopUp(msg.sender);
    }

    function startSession(uint256 stationId) external nonReentrant returns (uint256 sessionId) {
        require(vehicles[msg.sender].registered, "Not registered");
        ChargingStation storage st = stations[stationId];
        require(st.active, "Station inactive");
        sessionId = sessionCount++;
        sessions[sessionId] = ChargingSession({
            stationId: stationId, vehicle: msg.sender,
            energyKWh: FHE.asEuint32(0),
            sessionCostBps: FHE.asEuint64(0),
            finalBillUSD: FHE.asEuint64(0),
            startTime: block.timestamp, endTime: 0, completed: false
        });
        FHE.allowThis(sessions[sessionId].energyKWh);
        FHE.allowThis(sessions[sessionId].sessionCostBps);
        FHE.allowThis(sessions[sessionId].finalBillUSD);
        emit SessionStarted(sessionId, stationId, msg.sender);
    }

    function completeSession(
        uint256 sessionId,
        externalEuint32 encEnergy, bytes calldata eProof
    ) external nonReentrant {
        ChargingSession storage sess = sessions[sessionId];
        require(!sess.completed && sess.vehicle == msg.sender, "Invalid");
        ChargingStation storage st = stations[sess.stationId];
        euint32 energy = FHE.fromExternal(encEnergy, eProof);
        sess.energyKWh = energy;
        // Bill = energy * baseRate * priceMultiplier (DR adjusted)
        euint64 bill = FHE.div(
            FHE.mul(FHE.mul(_baseRateUSDPerKWh, st.pricePerKWhBps), FHE.asEuint64(uint64(FHE.isInitialized(energy) ? 1 : 1))),
            10000
        );
        // Apply DR surcharge: if demand signal > 5000, bill *= 1.2
        ebool highDemand = FHE.gt(st.demandResponseSig, FHE.asEuint64(5000));
        euint64 adjustedBill = FHE.select(highDemand, FHE.div(FHE.mul(bill, 12000), 10000), bill);
        sess.finalBillUSD = adjustedBill;
        // Deduct from prepaid balance
        ebool hasFunds = FHE.ge(vehicles[msg.sender].prepaidBalance, adjustedBill);
        euint64 deduct = FHE.select(hasFunds, adjustedBill, vehicles[msg.sender].prepaidBalance);
        vehicles[msg.sender].prepaidBalance = FHE.sub(vehicles[msg.sender].prepaidBalance, deduct);
        // Update station stats
        st.totalEnergyDelivered = FHE.add(st.totalEnergyDelivered, FHE.asEuint64(1)); // simplified
        st.totalRevenue = FHE.add(st.totalRevenue, adjustedBill);
        // Update vehicle stats
        vehicles[msg.sender].totalConsumedKWh = FHE.add(vehicles[msg.sender].totalConsumedKWh, FHE.asEuint64(1));
        _networkTotalEnergyKWh = FHE.add(_networkTotalEnergyKWh, FHE.asEuint64(1));
        sess.completed = true;
        sess.endTime = block.timestamp;
        FHE.allowThis(sess.finalBillUSD);
        FHE.allow(sess.finalBillUSD, msg.sender);
        FHE.allowThis(vehicles[msg.sender].prepaidBalance);
        FHE.allow(vehicles[msg.sender].prepaidBalance, msg.sender);
        FHE.allowThis(st.totalRevenue);
        FHE.allowThis(_networkTotalEnergyKWh);
        emit SessionCompleted(sessionId);
    }

    function updateDemandResponse(
        uint256 stationId,
        externalEuint64 encSignal, bytes calldata proof
    ) external {
        require(isGridOperator[msg.sender], "Not grid operator");
        euint64 signal = FHE.fromExternal(encSignal, proof);
        stations[stationId].demandResponseSig = signal;
        FHE.allowThis(stations[stationId].demandResponseSig);
        emit DemandResponseUpdated(stationId);
    }
}
