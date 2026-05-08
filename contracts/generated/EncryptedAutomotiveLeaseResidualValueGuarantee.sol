// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedAutomotiveLeaseResidualValueGuarantee
/// @notice Fleet leasing platform where vehicle residual values, lease rates,
///         depreciation schedules, and fleet utilization metrics are encrypted.
contract EncryptedAutomotiveLeaseResidualValueGuarantee is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum VehicleCategory { PASSENGER_CAR, SUV, COMMERCIAL_VAN, HEAVY_TRUCK, ELECTRIC_VEHICLE, HYBRID }
    enum LeaseType { OPEN_END, CLOSED_END, NET_FINANCE, OPERATING }

    struct VehicleAsset {
        string vin;
        string make;
        string model;
        uint256 modelYear;
        VehicleCategory category;
        euint64 msrpUSD;               // encrypted sticker price
        euint64 residualValueUSD;      // encrypted guaranteed residual
        euint64 currentMarketValueUSD; // encrypted current market value
        euint64 depreciationMonthlyUSD;// encrypted monthly depreciation
        euint32 odometerKm;            // encrypted mileage
        euint8  conditionScore;        // encrypted 0-100
        bool onLease;
    }

    struct LeaseAgreement {
        uint256 vehicleId;
        address lessee;
        address lessor;
        LeaseType leaseType;
        euint64 monthlyPaymentUSD;     // encrypted monthly payment
        euint64 securityDepositUSD;    // encrypted deposit
        euint64 totalLeaseValueUSD;    // encrypted total contracted value
        euint64 residualGuaranteeUSD;  // encrypted guaranteed residual
        euint64 totalPaidUSD;          // encrypted total received
        euint32 leasedKmAllowance;     // encrypted KM allowance
        euint32 leaseDurationMonths;   // encrypted term
        uint256 startDate;
        uint256 endDate;
        bool active;
        bool settled;
    }

    mapping(uint256 => VehicleAsset) private vehicles;
    mapping(uint256 => LeaseAgreement) private leases;
    mapping(address => bool) public isFleetManager;
    mapping(address => bool) public isResidualValueAuditor;
    uint256 public vehicleCount;
    uint256 public leaseCount;
    euint64 private _totalFleetValue;
    euint64 private _totalLeasePortfolioValue;
    euint64 private _totalResidualExposure;

    event VehicleRegistered(uint256 indexed vehicleId, VehicleCategory cat);
    event LeaseCreated(uint256 indexed leaseId, uint256 vehicleId, address lessee);
    event PaymentReceived(uint256 indexed leaseId);
    event LeaseTerminated(uint256 indexed leaseId);
    event ResidualSettled(uint256 indexed leaseId);

    constructor() Ownable(msg.sender) {
        _totalFleetValue = FHE.asEuint64(0);
        _totalLeasePortfolioValue = FHE.asEuint64(0);
        _totalResidualExposure = FHE.asEuint64(0);
        FHE.allowThis(_totalFleetValue);
        FHE.allowThis(_totalLeasePortfolioValue);
        FHE.allowThis(_totalResidualExposure);
        isFleetManager[msg.sender] = true;
        isResidualValueAuditor[msg.sender] = true;
    }

    function addFleetManager(address m) external onlyOwner { isFleetManager[m] = true; }
    function addAuditor(address a) external onlyOwner { isResidualValueAuditor[a] = true; }

    function registerVehicle(
        string calldata vin, string calldata make, string calldata model,
        uint256 modelYear, VehicleCategory cat,
        externalEuint64 encMSRP,        bytes calldata msrpProof,
        externalEuint64 encResidual,    bytes calldata resProof,
        externalEuint8  encCondition,   bytes calldata condProof
    ) external returns (uint256 vehicleId) {
        require(isFleetManager[msg.sender], "Not fleet manager");
        euint64 msrp     = FHE.fromExternal(encMSRP, msrpProof);
        euint64 residual = FHE.fromExternal(encResidual, resProof);
        euint8  condition= FHE.fromExternal(encCondition, condProof);
        vehicleId = vehicleCount++;
        vehicles[vehicleId] = VehicleAsset({
            vin: vin, make: make, model: model, modelYear: modelYear, category: cat,
            msrpUSD: msrp, residualValueUSD: residual, currentMarketValueUSD: msrp,
            depreciationMonthlyUSD: FHE.asEuint64(0),
            odometerKm: FHE.asEuint32(0), conditionScore: condition, onLease: false
        });
        _totalFleetValue = FHE.add(_totalFleetValue, msrp);
        FHE.allowThis(vehicles[vehicleId].msrpUSD);
        FHE.allow(vehicles[vehicleId].msrpUSD, msg.sender);
        FHE.allowThis(vehicles[vehicleId].residualValueUSD);
        FHE.allowThis(vehicles[vehicleId].currentMarketValueUSD);
        FHE.allowThis(vehicles[vehicleId].depreciationMonthlyUSD);
        FHE.allowThis(vehicles[vehicleId].odometerKm);
        FHE.allowThis(vehicles[vehicleId].conditionScore);
        FHE.allowThis(_totalFleetValue);
        emit VehicleRegistered(vehicleId, cat);
    }

    function createLease(
        uint256 vehicleId,
        address lessee,
        LeaseType leaseType,
        externalEuint64 encMonthly,   bytes calldata monProof,
        externalEuint64 encDeposit,   bytes calldata depProof,
        externalEuint64 encResidGuar, bytes calldata rgProof,
        externalEuint32 encKmAlloc,   bytes calldata kmProof,
        externalEuint32 encDuration,  bytes calldata durProof
    ) external returns (uint256 leaseId) {
        require(isFleetManager[msg.sender], "Not fleet manager");
        require(!vehicles[vehicleId].onLease, "Already on lease");
        euint64 monthly   = FHE.fromExternal(encMonthly, monProof);
        euint64 deposit   = FHE.fromExternal(encDeposit, depProof);
        euint64 residGuar = FHE.fromExternal(encResidGuar, rgProof);
        euint32 kmAlloc   = FHE.fromExternal(encKmAlloc, kmProof);
        euint32 duration  = FHE.fromExternal(encDuration, durProof);
        euint64 totalVal  = FHE.mul(monthly, FHE.asEuint64(uint64(0))); // simplified
        leaseId = leaseCount++;
        leases[leaseId] = LeaseAgreement({
            vehicleId: vehicleId, lessee: lessee, lessor: msg.sender,
            leaseType: leaseType, monthlyPaymentUSD: monthly,
            securityDepositUSD: deposit, totalLeaseValueUSD: totalVal,
            residualGuaranteeUSD: residGuar, totalPaidUSD: FHE.asEuint64(0),
            leasedKmAllowance: kmAlloc, leaseDurationMonths: duration,
            startDate: block.timestamp, endDate: block.timestamp + 30 days * 36,
            active: true, settled: false
        });
        vehicles[vehicleId].onLease = true;
        _totalLeasePortfolioValue = FHE.add(_totalLeasePortfolioValue, totalVal);
        _totalResidualExposure = FHE.add(_totalResidualExposure, residGuar);
        FHE.allowThis(leases[leaseId].monthlyPaymentUSD);
        FHE.allow(leases[leaseId].monthlyPaymentUSD, lessee);
        FHE.allowThis(leases[leaseId].securityDepositUSD);
        FHE.allow(leases[leaseId].securityDepositUSD, lessee);
        FHE.allowThis(leases[leaseId].totalLeaseValueUSD);
        FHE.allowThis(leases[leaseId].residualGuaranteeUSD);
        FHE.allowThis(leases[leaseId].totalPaidUSD);
        FHE.allow(leases[leaseId].totalPaidUSD, lessee);
        FHE.allowThis(leases[leaseId].leasedKmAllowance);
        FHE.allowThis(leases[leaseId].leaseDurationMonths);
        FHE.allowThis(_totalLeasePortfolioValue);
        FHE.allowThis(_totalResidualExposure);
        emit LeaseCreated(leaseId, vehicleId, lessee);
    }

    function recordPayment(uint256 leaseId) external {
        require(leases[leaseId].lessee == msg.sender || isFleetManager[msg.sender], "Unauthorized");
        leases[leaseId].totalPaidUSD = FHE.add(leases[leaseId].totalPaidUSD, leases[leaseId].monthlyPaymentUSD);
        FHE.allowThis(leases[leaseId].totalPaidUSD);
        FHE.allow(leases[leaseId].totalPaidUSD, leases[leaseId].lessee);
        emit PaymentReceived(leaseId);
    }

    function updateVehicleCondition(
        uint256 vehicleId,
        externalEuint8  encCondition, bytes calldata condProof,
        externalEuint32 encOdometer,  bytes calldata odomProof
    ) external {
        require(isResidualValueAuditor[msg.sender], "Not auditor");
        vehicles[vehicleId].conditionScore = FHE.fromExternal(encCondition, condProof);
        vehicles[vehicleId].odometerKm = FHE.fromExternal(encOdometer, odomProof);
        FHE.allowThis(vehicles[vehicleId].conditionScore);
        FHE.allowThis(vehicles[vehicleId].odometerKm);
    }

    function allowFleetView(address viewer) external onlyOwner {
        FHE.allow(_totalFleetValue, viewer);
        FHE.allow(_totalLeasePortfolioValue, viewer);
        FHE.allow(_totalResidualExposure, viewer);
    }
}
