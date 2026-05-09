// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateHospitalCapitalEquipmentLease
/// @notice Encrypted hospital capital equipment leasing: hidden lease rates, confidential
///         maintenance cost reserves, private equipment utilization metrics, and encrypted
///         residual value calculations for purchase options at lease end.
contract PrivateHospitalCapitalEquipmentLease is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum EquipmentType { MRIScanner, CTScanner, LinearAccelerator, RoboticSurgery, Ultrasound, LabAnalyzer }
    enum LeaseType { OperatingLease, FinanceLease, SaleAndLeaseback }

    struct EquipmentLease {
        address lessor;
        address hospital;
        EquipmentType equipmentType;
        string serialNumber;
        LeaseType leaseType;
        euint64 originalCostUSD;       // encrypted equipment purchase price
        euint64 monthlyLeaseRateUSD;   // encrypted monthly payment
        euint64 totalLeaseCommitmentUSD; // encrypted total commitment
        euint64 residualValueUSD;      // encrypted end-of-lease residual value
        euint64 maintenanceCostReserveUSD; // encrypted maintenance reserve
        euint16 utilizationRateBps;    // encrypted utilization %
        euint64 totalPaidUSD;          // encrypted total paid so far
        uint256 leaseStart;
        uint256 leaseEnd;
        bool purchaseOptionExercised;
    }

    mapping(uint256 => EquipmentLease) private leases;
    mapping(address => bool) public isHospital;
    mapping(address => bool) public isEquipmentVendor;

    uint256 public leaseCount;
    euint64 private _totalPortfolioValueUSD;
    euint64 private _totalMaintenanceReservesUSD;

    event LeaseCreated(uint256 indexed id, EquipmentType equipType, address hospital);
    event LeasePaymentMade(uint256 indexed id, uint256 paidAt);
    event PurchaseOptionExercised(uint256 indexed id, uint256 exercisedAt);

    modifier onlyHospital() {
        require(isHospital[msg.sender] || msg.sender == owner(), "Not hospital");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPortfolioValueUSD = FHE.asEuint64(0);
        _totalMaintenanceReservesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalPortfolioValueUSD);
        FHE.allowThis(_totalMaintenanceReservesUSD);
        isHospital[msg.sender] = true;
        isEquipmentVendor[msg.sender] = true;
    }

    function addHospital(address h) external onlyOwner { isHospital[h] = true; }
    function addEquipmentVendor(address v) external onlyOwner { isEquipmentVendor[v] = true; }

    function createEquipmentLease(
        address hospital,
        EquipmentType equipmentType,
        string calldata serialNumber,
        LeaseType leaseType,
        externalEuint64 encOrigCost, bytes calldata ocProof,
        externalEuint64 encMonthlyRate, bytes calldata mrProof,
        externalEuint64 encResidualValue, bytes calldata rvProof,
        externalEuint64 encMaintenanceReserve, bytes calldata mainProof,
        uint256 durationMonths
    ) external returns (uint256 id) {
        require(isEquipmentVendor[msg.sender], "Not equipment vendor");
        euint64 origCost = FHE.fromExternal(encOrigCost, ocProof);
        euint64 monthlyRate = FHE.fromExternal(encMonthlyRate, mrProof);
        euint64 residualVal = FHE.fromExternal(encResidualValue, rvProof);
        euint64 maintReserve = FHE.fromExternal(encMaintenanceReserve, mainProof);
        euint64 totalCommitment = FHE.mul(monthlyRate, FHE.asEuint64(uint64(durationMonths)));
        id = leaseCount++;
        EquipmentLease storage _s0 = leases[id];
        _s0.lessor = msg.sender;
        _s0.hospital = hospital;
        _s0.equipmentType = equipmentType;
        _s0.serialNumber = serialNumber;
        _s0.leaseType = leaseType;
        _s0.originalCostUSD = origCost;
        _s0.monthlyLeaseRateUSD = monthlyRate;
        _s0.totalLeaseCommitmentUSD = totalCommitment;
        _s0.residualValueUSD = residualVal;
        _s0.maintenanceCostReserveUSD = maintReserve;
        _s0.utilizationRateBps = FHE.asEuint16(0);
        _s0.totalPaidUSD = FHE.asEuint64(0);
        _s0.leaseStart = block.timestamp;
        _s0.leaseEnd = block.timestamp + durationMonths * 30 days;
        _s0.purchaseOptionExercised = false;
        _totalPortfolioValueUSD = FHE.add(_totalPortfolioValueUSD, origCost);
        _totalMaintenanceReservesUSD = FHE.add(_totalMaintenanceReservesUSD, maintReserve);
        FHE.allowThis(leases[id].originalCostUSD); FHE.allow(leases[id].originalCostUSD, msg.sender); FHE.allow(leases[id].originalCostUSD, hospital);
        FHE.allowThis(leases[id].monthlyLeaseRateUSD); FHE.allow(leases[id].monthlyLeaseRateUSD, hospital);
        FHE.allowThis(leases[id].totalLeaseCommitmentUSD); FHE.allow(leases[id].totalLeaseCommitmentUSD, hospital);
        FHE.allowThis(leases[id].residualValueUSD); FHE.allow(leases[id].residualValueUSD, hospital);
        FHE.allowThis(leases[id].maintenanceCostReserveUSD); FHE.allow(leases[id].maintenanceCostReserveUSD, hospital);
        FHE.allowThis(leases[id].utilizationRateBps);
        FHE.allowThis(leases[id].totalPaidUSD); FHE.allow(leases[id].totalPaidUSD, hospital);
        FHE.allowThis(_totalPortfolioValueUSD);
        FHE.allowThis(_totalMaintenanceReservesUSD);
        emit LeaseCreated(id, equipmentType, hospital);
    }

    function makeLeasePayment(uint256 leaseId) external onlyHospital nonReentrant {
        EquipmentLease storage l = leases[leaseId];
        require(msg.sender == l.hospital, "Not lessee hospital");
        l.totalPaidUSD = FHE.add(l.totalPaidUSD, l.monthlyLeaseRateUSD);
        FHE.allowThis(l.totalPaidUSD); FHE.allow(l.totalPaidUSD, l.hospital); FHE.allow(l.totalPaidUSD, l.lessor);
        emit LeasePaymentMade(leaseId, block.timestamp);
    }

    function reportUtilization(
        uint256 leaseId,
        externalEuint16 encUtilization, bytes calldata proof
    ) external {
        EquipmentLease storage l = leases[leaseId];
        require(msg.sender == l.hospital || msg.sender == owner(), "Not authorized");
        l.utilizationRateBps = FHE.fromExternal(encUtilization, proof);
        FHE.allowThis(l.utilizationRateBps); FHE.allow(l.utilizationRateBps, l.lessor);
    }

    function exercisePurchaseOption(uint256 leaseId) external onlyHospital nonReentrant {
        EquipmentLease storage l = leases[leaseId];
        require(msg.sender == l.hospital, "Not lessee hospital");
        require(!l.purchaseOptionExercised && block.timestamp >= l.leaseEnd, "Not eligible");
        l.purchaseOptionExercised = true;
        l.totalPaidUSD = FHE.add(l.totalPaidUSD, l.residualValueUSD);
        FHE.allowThis(l.totalPaidUSD); FHE.allow(l.totalPaidUSD, l.hospital);
        emit PurchaseOptionExercised(leaseId, block.timestamp);
    }

    function allowPortfolioStats(address viewer) external onlyOwner {
        FHE.allow(_totalPortfolioValueUSD, viewer);
        FHE.allow(_totalMaintenanceReservesUSD, viewer);
    }
}
