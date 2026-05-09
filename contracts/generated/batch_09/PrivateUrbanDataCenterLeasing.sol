// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateUrbanDataCenterLeasing
/// @notice Encrypted data center colocation leasing: hidden power density pricing,
///         confidential cooling efficiency metrics, private wholesale customer discounts,
///         and encrypted carbon footprint allocations per rack.
contract PrivateUrbanDataCenterLeasing is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum TierLevel { Tier1, Tier2, Tier3, Tier4 }
    enum PowerDensity { Low5kW, Mid10kW, High20kW, UltraHigh40kW }

    struct DataCenterLease {
        address landlord;
        address tenant;
        string facilityRef;
        TierLevel tierLevel;
        PowerDensity powerDensity;
        euint32 cabinetCount;          // encrypted cabinet count
        euint64 monthlyRentUSD;        // encrypted monthly rent
        euint64 powerCostPerKWhUSD;    // encrypted power rate
        euint16 pueRatioBps;           // encrypted PUE efficiency
        euint64 totalCommitmentUSD;    // encrypted total lease value
        euint64 totalPaidUSD;          // encrypted paid to date
        euint32 carbonKgPerMonth;      // encrypted carbon footprint
        uint256 leaseStart;
        uint256 leaseEnd;
        bool active;
    }

    mapping(uint256 => DataCenterLease) private leases;
    mapping(address => bool) public isDataCenterOperator;

    uint256 public leaseCount;
    euint64 private _totalLeaseRevenueUSD;
    euint32 private _totalCarbonFootprintKg;

    event LeaseCreated(uint256 indexed id, TierLevel tier, PowerDensity density);
    event MonthlyPaymentMade(uint256 indexed id, uint256 paidAt);

    modifier onlyDataCenterOperator() {
        require(isDataCenterOperator[msg.sender] || msg.sender == owner(), "Not DC operator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalLeaseRevenueUSD = FHE.asEuint64(0);
        _totalCarbonFootprintKg = FHE.asEuint32(0);
        FHE.allowThis(_totalLeaseRevenueUSD);
        FHE.allowThis(_totalCarbonFootprintKg);
        isDataCenterOperator[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isDataCenterOperator[op] = true; }

    function createLease(
        address tenant, string calldata facilityRef, TierLevel tierLevel, PowerDensity powerDensity,
        externalEuint32 encCabinets, bytes calldata cabProof,
        externalEuint64 encMonthlyRent, bytes calldata mrProof,
        externalEuint64 encPowerRate, bytes calldata prProof,
        externalEuint16 encPUE, bytes calldata pueProof,
        externalEuint32 encCarbonKg, bytes calldata cProof,
        uint256 termMonths
    ) external onlyDataCenterOperator returns (uint256 id) {
        euint32 cabinets = FHE.fromExternal(encCabinets, cabProof);
        euint64 monthlyRent = FHE.fromExternal(encMonthlyRent, mrProof);
        euint64 powerRate = FHE.fromExternal(encPowerRate, prProof);
        euint16 pue = FHE.fromExternal(encPUE, pueProof);
        euint32 carbonKg = FHE.fromExternal(encCarbonKg, cProof);
        euint64 totalCommit = FHE.mul(monthlyRent, FHE.asEuint64(uint64(termMonths)));
        id = leaseCount++;
        DataCenterLease storage _s0 = leases[id];
        _s0.landlord = msg.sender;
        _s0.tenant = tenant;
        _s0.facilityRef = facilityRef;
        _s0.tierLevel = tierLevel;
        _s0.powerDensity = powerDensity;
        _s0.cabinetCount = cabinets;
        _s0.monthlyRentUSD = monthlyRent;
        _s0.powerCostPerKWhUSD = powerRate;
        _s0.pueRatioBps = pue;
        _s0.totalCommitmentUSD = totalCommit;
        _s0.totalPaidUSD = FHE.asEuint64(0);
        _s0.carbonKgPerMonth = carbonKg;
        _s0.leaseStart = block.timestamp;
        _s0.leaseEnd = block.timestamp + termMonths * 30 days;
        _s0.active = true;
        _totalCarbonFootprintKg = FHE.add(_totalCarbonFootprintKg, carbonKg);
        FHE.allowThis(leases[id].cabinetCount); FHE.allow(leases[id].cabinetCount, tenant);
        FHE.allowThis(leases[id].monthlyRentUSD); FHE.allow(leases[id].monthlyRentUSD, tenant);
        FHE.allowThis(leases[id].powerCostPerKWhUSD); FHE.allow(leases[id].powerCostPerKWhUSD, tenant);
        FHE.allowThis(leases[id].pueRatioBps);
        FHE.allowThis(leases[id].totalCommitmentUSD); FHE.allow(leases[id].totalCommitmentUSD, tenant);
        FHE.allowThis(leases[id].totalPaidUSD); FHE.allow(leases[id].totalPaidUSD, tenant);
        FHE.allowThis(leases[id].carbonKgPerMonth); FHE.allow(leases[id].carbonKgPerMonth, tenant);
        FHE.allowThis(_totalCarbonFootprintKg);
        emit LeaseCreated(id, tierLevel, powerDensity);
    }

    function makeMonthlyPayment(uint256 leaseId) external nonReentrant {
        DataCenterLease storage l = leases[leaseId];
        require(msg.sender == l.tenant && l.active, "Not authorized");
        l.totalPaidUSD = FHE.add(l.totalPaidUSD, l.monthlyRentUSD);
        _totalLeaseRevenueUSD = FHE.add(_totalLeaseRevenueUSD, l.monthlyRentUSD);
        FHE.allowThis(l.totalPaidUSD); FHE.allow(l.totalPaidUSD, l.tenant); FHE.allow(l.totalPaidUSD, l.landlord);
        FHE.allowThis(_totalLeaseRevenueUSD);
        emit MonthlyPaymentMade(leaseId, block.timestamp);
    }

    function allowFacilityStats(address viewer) external onlyOwner {
        FHE.allow(_totalLeaseRevenueUSD, viewer);
        FHE.allow(_totalCarbonFootprintKg, viewer);
    }
}
