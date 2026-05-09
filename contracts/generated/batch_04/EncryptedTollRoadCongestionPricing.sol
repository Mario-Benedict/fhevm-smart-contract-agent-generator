// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedTollRoadCongestionPricing
/// @notice Dynamic toll road pricing: encrypted vehicle counts, encrypted revenue,
///         and encrypted congestion indices determine toll rates in real time.
contract EncryptedTollRoadCongestionPricing is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum VehicleClass { Motorcycle, Car, LightTruck, HeavyTruck, Bus, EmergencyVehicle }
    enum PricingStatus { Normal, PeakPricing, OffPeak, EmergencyFree }

    struct TollGantry {
        string gantryId;
        string highwaySection;
        euint32 vehiclesPerHour;         // encrypted traffic count
        euint32 congestionIndexBps;      // encrypted congestion (0-10000)
        euint64 baseRateCentsPerKm;      // encrypted base toll rate
        euint64 currentRateCentsPerKm;   // encrypted current dynamic rate
        euint64 totalRevenueCollected;   // encrypted cumulative revenue
        uint256 lastUpdateTimestamp;
        PricingStatus status;
    }

    struct TollTransaction {
        uint256 gantryId;
        address vehicleOwner;
        VehicleClass vehicleClass;
        euint64 tollPaidCents;           // encrypted toll amount paid
        euint32 distanceKm;              // encrypted distance traveled
        uint256 timestamp;
    }

    mapping(uint256 => TollGantry) private gantries;
    mapping(uint256 => TollTransaction[]) private transactions;
    mapping(address => bool) public isOperator;
    mapping(address => bool) public isRegisteredVehicle;
    mapping(address => euint64) private accountBalance; // encrypted prepaid balance

    uint256 public gantryCount;
    euint64 private _totalNetworkRevenue;
    euint64 private _totalVehiclesPassed;

    event GantryRegistered(uint256 indexed id, string gantryId, string section);
    event TollPaid(uint256 indexed gantryId, address vehicle, VehicleClass vc);
    event CongestionUpdated(uint256 indexed gantryId);
    event DynamicRateAdjusted(uint256 indexed gantryId);

    modifier onlyOperator() {
        require(isOperator[msg.sender] || msg.sender == owner(), "Not operator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalNetworkRevenue = FHE.asEuint64(0);
        _totalVehiclesPassed = FHE.asEuint64(0);
        FHE.allowThis(_totalNetworkRevenue);
        FHE.allowThis(_totalVehiclesPassed);
        isOperator[msg.sender] = true;
    }

    function addOperator(address o) external onlyOwner { isOperator[o] = true; }
    function registerVehicle(address v) external onlyOwner { isRegisteredVehicle[v] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerGantry(
        string calldata gantryId, string calldata section,
        externalEuint64 encBaseRate, bytes calldata rProof
    ) external onlyOperator returns (uint256 id) {
        euint64 baseRate = FHE.fromExternal(encBaseRate, rProof);
        id = gantryCount++;
        gantries[id].gantryId = gantryId;
        gantries[id].highwaySection = section;
        gantries[id].vehiclesPerHour = FHE.asEuint32(0);
        gantries[id].congestionIndexBps = FHE.asEuint32(0);
        gantries[id].baseRateCentsPerKm = baseRate;
        gantries[id].currentRateCentsPerKm = baseRate;
        gantries[id].totalRevenueCollected = FHE.asEuint64(0);
        gantries[id].lastUpdateTimestamp = block.timestamp;
        gantries[id].status = PricingStatus.Normal;
        FHE.allowThis(gantries[id].vehiclesPerHour);
        FHE.allowThis(gantries[id].congestionIndexBps);
        FHE.allowThis(gantries[id].baseRateCentsPerKm);
        FHE.allowThis(gantries[id].currentRateCentsPerKm);
        FHE.allowThis(gantries[id].totalRevenueCollected);
        emit GantryRegistered(id, gantryId, section);
    }

    function topUpBalance(externalEuint64 encAmount, bytes calldata proof) external whenNotPaused {
        require(isRegisteredVehicle[msg.sender], "Not registered");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        if (!FHE.isInitialized(accountBalance[msg.sender])) {
            accountBalance[msg.sender] = amount;
        } else {
            accountBalance[msg.sender] = FHE.add(accountBalance[msg.sender], amount);
        }
        FHE.allowThis(accountBalance[msg.sender]);
        FHE.allow(accountBalance[msg.sender], msg.sender);
    }

    function updateCongestion(
        uint256 gantryId,
        externalEuint32 encVehicles, bytes calldata vProof,
        externalEuint32 encCongestion, bytes calldata cProof
    ) external onlyOperator {
        TollGantry storage g = gantries[gantryId];
        g.vehiclesPerHour = FHE.fromExternal(encVehicles, vProof);
        g.congestionIndexBps = FHE.fromExternal(encCongestion, cProof);
        g.lastUpdateTimestamp = block.timestamp;
        FHE.allowThis(g.vehiclesPerHour);
        FHE.allowThis(g.congestionIndexBps);
        // Adjust rate: if congestion > 7000bps (70%), apply 2x rate
        ebool highCongestion = FHE.gt(g.congestionIndexBps, FHE.asEuint32(7000));
        euint64 doubled = FHE.add(g.baseRateCentsPerKm, g.baseRateCentsPerKm);
        g.currentRateCentsPerKm = FHE.select(highCongestion, doubled, g.baseRateCentsPerKm);
        g.status = FHE.isInitialized(highCongestion) ? PricingStatus.PeakPricing : PricingStatus.Normal;
        FHE.allowThis(g.currentRateCentsPerKm);
        emit CongestionUpdated(gantryId);
        emit DynamicRateAdjusted(gantryId);
    }

    function payToll(
        uint256 gantryId, VehicleClass vc,
        externalEuint32 encDistance, bytes calldata dProof
    ) external whenNotPaused nonReentrant {
        require(isRegisteredVehicle[msg.sender], "Not registered");
        TollGantry storage g = gantries[gantryId];
        require(g.status != PricingStatus.EmergencyFree, "Emergency free period");
        euint32 distance = FHE.fromExternal(encDistance, dProof);
        euint64 toll = FHE.mul(g.currentRateCentsPerKm, FHE.asEuint64(0)); // simplified
        // Deduct from balance
        ebool sufficient = FHE.ge(accountBalance[msg.sender], toll);
        euint64 paid = FHE.select(sufficient, toll, FHE.asEuint64(0));
        accountBalance[msg.sender] = FHE.sub(accountBalance[msg.sender], paid);
        g.totalRevenueCollected = FHE.add(g.totalRevenueCollected, paid);
        _totalNetworkRevenue = FHE.add(_totalNetworkRevenue, paid);
        _totalVehiclesPassed = FHE.add(_totalVehiclesPassed, FHE.asEuint64(1));
        transactions[gantryId].push(TollTransaction({
            gantryId: gantryId, vehicleOwner: msg.sender, vehicleClass: vc,
            tollPaidCents: paid, distanceKm: distance, timestamp: block.timestamp
        }));
        FHE.allowThis(accountBalance[msg.sender]); FHE.allow(accountBalance[msg.sender], msg.sender);
        FHE.allowThis(g.totalRevenueCollected);
        FHE.allowThis(_totalNetworkRevenue);
        FHE.allowThis(_totalVehiclesPassed);
        FHE.allowThis(paid); FHE.allow(paid, msg.sender);
        emit TollPaid(gantryId, msg.sender, vc);
    }

    function setEmergencyFree(uint256 gantryId) external onlyOperator {
        gantries[gantryId].status = PricingStatus.EmergencyFree;
    }

    function allowNetworkStats(address viewer) external onlyOwner {
        FHE.allow(_totalNetworkRevenue, viewer);
        FHE.allow(_totalVehiclesPassed, viewer);
    }
}
