// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedTaxiFleetDynamicPricing
/// @notice Ride-hailing fleet management with encrypted surge pricing multipliers,
///         driver earnings, and passenger demand scores kept confidential.
contract EncryptedTaxiFleetDynamicPricing is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum VehicleClass { ECONOMY, COMFORT, PREMIUM, SUV, ELECTRIC, MOTO }
    enum RideStatus { PENDING, MATCHED, IN_PROGRESS, COMPLETED, CANCELLED }

    struct Driver {
        euint64 totalEarningsUSD;      // encrypted earnings
        euint64 weeklyEarningsUSD;     // encrypted weekly
        euint32 totalRidesCompleted;   // encrypted count
        euint8  ratingScore;           // encrypted 0-100 rating
        euint8  acceptanceRatePct;     // encrypted acceptance %
        euint8  cancellationRatePct;   // encrypted cancellation %
        VehicleClass vehicleClass;
        bool active;
    }

    struct RideRequest {
        address passenger;
        address driver;
        VehicleClass vehicleClass;
        euint64 baseFareUSD;           // encrypted base fare
        euint64 surgeMultiplierBps;    // encrypted surge (10000 = 1x)
        euint64 finalFareUSD;          // encrypted actual charged
        euint64 driverPayout;          // encrypted driver's share
        euint32 distanceMeters;        // encrypted route distance
        uint256 requestTime;
        uint256 completionTime;
        RideStatus status;
    }

    struct ZoneMetrics {
        string zoneName;
        euint32 activeDrivers;         // encrypted driver count
        euint32 demandScore;           // encrypted demand 0-1000
        euint64 currentSurgeBps;       // encrypted surge multiplier
        euint64 avgWaitTimeSeconds;    // encrypted wait time
    }

    mapping(address => Driver) private drivers;
    mapping(uint256 => RideRequest) private rides;
    mapping(uint256 => ZoneMetrics) private zones;
    mapping(address => bool) public isFleetOperator;
    uint256 public rideCount;
    uint256 public zoneCount;
    euint64 private _totalGMV;         // encrypted gross merchandise value
    euint64 private _totalDriverPayout;
    euint64 private _platformRevenue;
    euint32 private _platformFeeBps;

    event DriverRegistered(address indexed driver);
    event RideRequested(uint256 indexed rideId);
    event RideCompleted(uint256 indexed rideId);
    event SurgeUpdated(uint256 indexed zoneId);

    constructor(uint32 feeBps) Ownable(msg.sender) {
        _platformFeeBps = FHE.asEuint32(feeBps);
        _totalGMV = FHE.asEuint64(0);
        _totalDriverPayout = FHE.asEuint64(0);
        _platformRevenue = FHE.asEuint64(0);
        FHE.allowThis(_platformFeeBps);
        FHE.allowThis(_totalGMV);
        FHE.allowThis(_totalDriverPayout);
        FHE.allowThis(_platformRevenue);
        isFleetOperator[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isFleetOperator[op] = true; }

    function registerDriver(VehicleClass vClass) external {
        drivers[msg.sender] = Driver({
            totalEarningsUSD: FHE.asEuint64(0),
            weeklyEarningsUSD: FHE.asEuint64(0),
            totalRidesCompleted: FHE.asEuint32(0),
            ratingScore: FHE.asEuint8(80),
            acceptanceRatePct: FHE.asEuint8(100),
            cancellationRatePct: FHE.asEuint8(0),
            vehicleClass: vClass,
            active: true
        });
        FHE.allowThis(drivers[msg.sender].totalEarningsUSD);
        FHE.allow(drivers[msg.sender].totalEarningsUSD, msg.sender);
        FHE.allowThis(drivers[msg.sender].weeklyEarningsUSD);
        FHE.allow(drivers[msg.sender].weeklyEarningsUSD, msg.sender);
        FHE.allowThis(drivers[msg.sender].totalRidesCompleted);
        FHE.allowThis(drivers[msg.sender].ratingScore);
        FHE.allow(drivers[msg.sender].ratingScore, msg.sender);
        FHE.allowThis(drivers[msg.sender].acceptanceRatePct);
        FHE.allowThis(drivers[msg.sender].cancellationRatePct);
        emit DriverRegistered(msg.sender);
    }

    function createZone(
        string calldata name,
        externalEuint32 encDemand,  bytes calldata dProof,
        externalEuint64 encSurge,   bytes calldata sProof
    ) external returns (uint256 zoneId) {
        require(isFleetOperator[msg.sender], "Not operator");
        euint32 demand = FHE.fromExternal(encDemand, dProof);
        euint64 surge  = FHE.fromExternal(encSurge, sProof);
        zoneId = zoneCount++;
        zones[zoneId] = ZoneMetrics({
            zoneName: name, activeDrivers: FHE.asEuint32(0),
            demandScore: demand, currentSurgeBps: surge,
            avgWaitTimeSeconds: FHE.asEuint64(180)
        });
        FHE.allowThis(zones[zoneId].activeDrivers);
        FHE.allowThis(zones[zoneId].demandScore);
        FHE.allowThis(zones[zoneId].currentSurgeBps);
        FHE.allowThis(zones[zoneId].avgWaitTimeSeconds);
    }

    function requestRide(
        uint256 zoneId,
        VehicleClass vClass,
        externalEuint64 encBaseFare, bytes calldata proof
    ) external nonReentrant returns (uint256 rideId) {
        euint64 baseFare = FHE.fromExternal(encBaseFare, proof);
        euint64 surge = zones[zoneId].currentSurgeBps;
        euint64 finalFare = FHE.div(FHE.mul(baseFare, surge), 10000);
        euint64 platformFee = FHE.div(FHE.mul(finalFare, 0), 10000);
        euint64 driverPayout = FHE.sub(finalFare, platformFee);
        rideId = rideCount++;
        rides[rideId] = RideRequest({
            passenger: msg.sender, driver: address(0), vehicleClass: vClass,
            baseFareUSD: baseFare, surgeMultiplierBps: surge, finalFareUSD: finalFare,
            driverPayout: driverPayout, distanceMeters: FHE.asEuint32(0),
            requestTime: block.timestamp, completionTime: 0, status: RideStatus.PENDING
        });
        FHE.allowThis(rides[rideId].baseFareUSD);
        FHE.allow(rides[rideId].baseFareUSD, msg.sender);
        FHE.allowThis(rides[rideId].finalFareUSD);
        FHE.allow(rides[rideId].finalFareUSD, msg.sender);
        FHE.allowThis(rides[rideId].surgeMultiplierBps);
        FHE.allowThis(rides[rideId].driverPayout);
        FHE.allowThis(rides[rideId].distanceMeters);
        emit RideRequested(rideId);
    }

    function completeRide(uint256 rideId, address driver) external nonReentrant {
        require(isFleetOperator[msg.sender], "Not operator");
        RideRequest storage ride = rides[rideId];
        ride.driver = driver;
        ride.status = RideStatus.COMPLETED;
        ride.completionTime = block.timestamp;
        drivers[driver].totalEarningsUSD = FHE.add(drivers[driver].totalEarningsUSD, ride.driverPayout);
        drivers[driver].weeklyEarningsUSD = FHE.add(drivers[driver].weeklyEarningsUSD, ride.driverPayout);
        drivers[driver].totalRidesCompleted = FHE.add(drivers[driver].totalRidesCompleted, FHE.asEuint32(1));
        _totalGMV = FHE.add(_totalGMV, ride.finalFareUSD);
        _totalDriverPayout = FHE.add(_totalDriverPayout, ride.driverPayout);
        _platformRevenue = FHE.add(_platformRevenue, FHE.sub(ride.finalFareUSD, ride.driverPayout));
        FHE.allow(ride.driverPayout, driver);
        FHE.allowThis(drivers[driver].totalEarningsUSD);
        FHE.allow(drivers[driver].totalEarningsUSD, driver);
        FHE.allowThis(drivers[driver].totalRidesCompleted);
        FHE.allowThis(_totalGMV);
        FHE.allowThis(_totalDriverPayout);
        FHE.allowThis(_platformRevenue);
        emit RideCompleted(rideId);
    }

    function updateZoneSurge(uint256 zoneId, externalEuint64 encSurge, bytes calldata proof) external {
        require(isFleetOperator[msg.sender], "Not operator");
        zones[zoneId].currentSurgeBps = FHE.fromExternal(encSurge, proof);
        FHE.allowThis(zones[zoneId].currentSurgeBps);
        emit SurgeUpdated(zoneId);
    }

    function allowPlatformView(address viewer) external onlyOwner {
        FHE.allow(_totalGMV, viewer);
        FHE.allow(_totalDriverPayout, viewer);
        FHE.allow(_platformRevenue, viewer);
    }
}
