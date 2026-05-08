// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateElectricVehicleFleetLease
/// @notice Fleet leasing platform for EV fleets: encrypted lease rates, encrypted
///         battery health scores, and encrypted residual values.
contract PrivateElectricVehicleFleetLease is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum VehicleType { PassengerEV, LightCommercialEV, HeavyTruckEV, ElectricBus, ElectricVan }
    enum LeaseStatus { Available, Leased, UnderMaintenance, EndOfLife, Recalled }

    struct EVAsset {
        string vin;
        VehicleType vehicleType;
        string make;
        string model;
        uint256 modelYear;
        euint32 batteryCapacityKWh;     // encrypted battery size
        euint32 batteryHealthPercBps;   // encrypted state of health (SoH)
        euint64 residualValueUSD;       // encrypted residual value
        euint32 odometer;              // encrypted mileage
        euint64 currentLeaseRateUSD;   // encrypted monthly rate
        LeaseStatus status;
        address currentLessee;
    }

    struct FleetLease {
        address lessee;
        uint256 vehicleId;
        euint64 monthlyRateUSD;         // encrypted rate
        euint32 contractedMileage;      // encrypted mileage cap
        euint64 depositUSD;             // encrypted security deposit
        euint64 totalPaidUSD;          // encrypted cumulative payments
        euint32 excessMileageRateCents; // encrypted excess rate
        uint256 startDate;
        uint256 endDate;
        bool active;
    }

    mapping(uint256 => EVAsset) private assets;
    mapping(uint256 => FleetLease) private leases;
    mapping(address => bool) public isFleetManager;
    mapping(address => bool) public isTelematics;    // IoT/OBD oracle

    uint256 public assetCount;
    uint256 public leaseCount;
    euint64 private _totalFleetValueUSD;
    euint64 private _totalLeaseRevenue;

    event AssetRegistered(uint256 indexed id, string vin, VehicleType vType);
    event LeaseCreated(uint256 indexed id, address lessee, uint256 vehicleId);
    event PaymentReceived(uint256 indexed leaseId);
    event BatteryHealthUpdated(uint256 indexed vehicleId);
    event LeaseTerminated(uint256 indexed leaseId);

    modifier onlyFleetManager() {
        require(isFleetManager[msg.sender] || msg.sender == owner(), "Not fleet manager");
        _;
    }

    modifier onlyTelematics() {
        require(isTelematics[msg.sender] || msg.sender == owner(), "Not telematics");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalFleetValueUSD = FHE.asEuint64(0);
        _totalLeaseRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalFleetValueUSD);
        FHE.allowThis(_totalLeaseRevenue);
        isFleetManager[msg.sender] = true;
        isTelematics[msg.sender] = true;
    }

    function addFleetManager(address f) external onlyOwner { isFleetManager[f] = true; }
    function addTelematics(address t) external onlyOwner { isTelematics[t] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerAsset(
        string calldata vin, VehicleType vType,
        string calldata make, string calldata model, uint256 modelYear,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint32 encSoH, bytes calldata sohProof,
        externalEuint64 encResidual, bytes calldata rProof
    ) external onlyFleetManager whenNotPaused returns (uint256 id) {
        euint32 cap = FHE.fromExternal(encCapacity, capProof);
        euint32 soh = FHE.fromExternal(encSoH, sohProof);
        euint64 residual = FHE.fromExternal(encResidual, rProof);
        id = assetCount++;
        assets[id] = EVAsset({
            vin: vin, vehicleType: vType, make: make, model: model, modelYear: modelYear,
            batteryCapacityKWh: cap, batteryHealthPercBps: soh, residualValueUSD: residual,
            odometer: FHE.asEuint32(0), currentLeaseRateUSD: FHE.asEuint64(0),
            status: LeaseStatus.Available, currentLessee: address(0)
        });
        _totalFleetValueUSD = FHE.add(_totalFleetValueUSD, residual);
        FHE.allowThis(assets[id].batteryCapacityKWh); FHE.allow(assets[id].batteryCapacityKWh, msg.sender);
        FHE.allowThis(assets[id].batteryHealthPercBps); FHE.allow(assets[id].batteryHealthPercBps, msg.sender);
        FHE.allowThis(assets[id].residualValueUSD); FHE.allow(assets[id].residualValueUSD, msg.sender);
        FHE.allowThis(assets[id].odometer);
        FHE.allowThis(assets[id].currentLeaseRateUSD);
        FHE.allowThis(_totalFleetValueUSD);
        emit AssetRegistered(id, vin, vType);
    }

    function createLease(
        address lessee, uint256 vehicleId,
        externalEuint64 encRate, bytes calldata rProof,
        externalEuint32 encMileage, bytes calldata mProof,
        externalEuint64 encDeposit, bytes calldata dProof,
        externalEuint32 encExcessRate, bytes calldata erProof,
        uint256 leaseDays
    ) external onlyFleetManager nonReentrant returns (uint256 id) {
        EVAsset storage a = assets[vehicleId];
        require(a.status == LeaseStatus.Available, "Not available");
        euint64 rate = FHE.fromExternal(encRate, rProof);
        euint32 mileage = FHE.fromExternal(encMileage, mProof);
        euint64 deposit = FHE.fromExternal(encDeposit, dProof);
        euint32 excessRate = FHE.fromExternal(encExcessRate, erProof);
        id = leaseCount++;
        leases[id] = FleetLease({
            lessee: lessee, vehicleId: vehicleId, monthlyRateUSD: rate,
            contractedMileage: mileage, depositUSD: deposit,
            totalPaidUSD: FHE.asEuint64(0), excessMileageRateCents: excessRate,
            startDate: block.timestamp, endDate: block.timestamp + leaseDays * 1 days,
            active: true
        });
        a.status = LeaseStatus.Leased;
        a.currentLessee = lessee;
        a.currentLeaseRateUSD = rate;
        FHE.allowThis(leases[id].monthlyRateUSD); FHE.allow(leases[id].monthlyRateUSD, lessee);
        FHE.allowThis(leases[id].contractedMileage); FHE.allow(leases[id].contractedMileage, lessee);
        FHE.allowThis(leases[id].depositUSD); FHE.allow(leases[id].depositUSD, lessee);
        FHE.allowThis(leases[id].totalPaidUSD); FHE.allow(leases[id].totalPaidUSD, lessee);
        FHE.allowThis(leases[id].excessMileageRateCents); FHE.allow(leases[id].excessMileageRateCents, lessee);
        FHE.allowThis(a.currentLeaseRateUSD);
        emit LeaseCreated(id, lessee, vehicleId);
    }

    function recordPayment(uint256 leaseId, externalEuint64 encPayment, bytes calldata proof) external onlyFleetManager {
        FleetLease storage l = leases[leaseId];
        require(l.active, "Not active");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        l.totalPaidUSD = FHE.add(l.totalPaidUSD, payment);
        _totalLeaseRevenue = FHE.add(_totalLeaseRevenue, payment);
        FHE.allowThis(l.totalPaidUSD); FHE.allow(l.totalPaidUSD, l.lessee);
        FHE.allowThis(_totalLeaseRevenue);
        emit PaymentReceived(leaseId);
    }

    function updateBatteryHealth(uint256 vehicleId, externalEuint32 encSoH, bytes calldata proof) external onlyTelematics {
        assets[vehicleId].batteryHealthPercBps = FHE.fromExternal(encSoH, proof);
        FHE.allowThis(assets[vehicleId].batteryHealthPercBps);
        FHE.allow(assets[vehicleId].batteryHealthPercBps, assets[vehicleId].currentLessee);
        emit BatteryHealthUpdated(vehicleId);
    }

    function updateOdometer(uint256 vehicleId, externalEuint32 encOdo, bytes calldata proof) external onlyTelematics {
        assets[vehicleId].odometer = FHE.fromExternal(encOdo, proof);
        FHE.allowThis(assets[vehicleId].odometer);
        FHE.allow(assets[vehicleId].odometer, assets[vehicleId].currentLessee);
    }

    function terminateLease(uint256 leaseId) external onlyFleetManager {
        FleetLease storage l = leases[leaseId];
        l.active = false;
        assets[l.vehicleId].status = LeaseStatus.Available;
        assets[l.vehicleId].currentLessee = address(0);
        emit LeaseTerminated(leaseId);
    }

    function allowFleetStats(address viewer) external onlyOwner {
        FHE.allow(_totalFleetValueUSD, viewer);
        FHE.allow(_totalLeaseRevenue, viewer);
    }
}
