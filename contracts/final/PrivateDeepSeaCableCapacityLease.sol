// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateDeepSeaCableCapacityLease
/// @notice Encrypted submarine cable capacity leasing: hidden bandwidth allocations per tenant,
///         confidential dark fiber pricing, private restoration priority levels, and encrypted
///         SLA penalty calculations for outage events.
contract PrivateDeepSeaCableCapacityLease is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FiberType { DarkFiber, LitCapacity, IRU, Wavelength }

    struct CableSystem {
        string cableSystemName;
        string routeDescription;
        address operator;
        euint64 totalCapacityGbps;    // encrypted total capacity
        euint64 leasedCapacityGbps;   // encrypted leased portion
        euint64 annualMaintenanceCostUSD; // encrypted maintenance cost
        bool active;
    }

    struct CapacityLease {
        uint256 cableId;
        address lessee;
        FiberType fiberType;
        euint32 allocatedGbps;         // encrypted bandwidth
        euint64 annualLeaseRateUSD;    // encrypted lease rate
        euint8  restorationPriority;   // encrypted priority level (1=highest)
        euint64 totalSLAPenaltiesUSD;  // encrypted accumulated penalties
        uint256 leaseStart;
        uint256 leaseEnd;
        bool active;
    }

    mapping(uint256 => CableSystem) private cableSystems;
    mapping(uint256 => CapacityLease) private leases;
    mapping(address => bool) public isCapacityBroker;

    uint256 public cableCount;
    uint256 public leaseCount;
    euint64 private _totalLeaseRevenueUSD;
    euint64 private _totalPenaltiesPaidUSD;

    event CableRegistered(uint256 indexed id, string name);
    event LeaseCreated(uint256 indexed leaseId, uint256 cableId, address lessee);
    event SLAPenaltyApplied(uint256 indexed leaseId, uint256 appliedAt);

    modifier onlyBroker() {
        require(isCapacityBroker[msg.sender] || msg.sender == owner(), "Not broker");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalLeaseRevenueUSD = FHE.asEuint64(0);
        _totalPenaltiesPaidUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalLeaseRevenueUSD);
        FHE.allowThis(_totalPenaltiesPaidUSD);
        isCapacityBroker[msg.sender] = true;
    }

    function addBroker(address b) external onlyOwner { isCapacityBroker[b] = true; }

    function registerCableSystem(
        string calldata name, string calldata route,
        externalEuint64 encCapacity, bytes calldata capProof,
        externalEuint64 encMaint, bytes calldata maintProof
    ) external returns (uint256 id) {
        euint64 cap = FHE.fromExternal(encCapacity, capProof);
        euint64 maint = FHE.fromExternal(encMaint, maintProof);
        id = cableCount++;
        cableSystems[id] = CableSystem({
            cableSystemName: name, routeDescription: route, operator: msg.sender,
            totalCapacityGbps: cap, leasedCapacityGbps: FHE.asEuint64(0),
            annualMaintenanceCostUSD: maint, active: true
        });
        FHE.allowThis(cableSystems[id].totalCapacityGbps); FHE.allow(cableSystems[id].totalCapacityGbps, msg.sender);
        FHE.allowThis(cableSystems[id].leasedCapacityGbps); FHE.allow(cableSystems[id].leasedCapacityGbps, msg.sender);
        FHE.allowThis(cableSystems[id].annualMaintenanceCostUSD); FHE.allow(cableSystems[id].annualMaintenanceCostUSD, msg.sender);
        emit CableRegistered(id, name);
    }

    function createLease(
        uint256 cableId,
        address lessee,
        FiberType fiberType,
        externalEuint32 encGbps, bytes calldata gbpsProof,
        externalEuint64 encRate, bytes calldata rateProof,
        externalEuint8 encPriority, bytes calldata priProof,
        uint256 durationDays
    ) external onlyBroker nonReentrant returns (uint256 leaseId) {
        euint32 gbps = FHE.fromExternal(encGbps, gbpsProof);
        euint64 rate = FHE.fromExternal(encRate, rateProof);
        euint8 priority = FHE.fromExternal(encPriority, priProof);
        CableSystem storage cs = cableSystems[cableId];
        cs.leasedCapacityGbps = FHE.add(cs.leasedCapacityGbps, FHE.asEuint64(uint64(1)));
        leaseId = leaseCount++;
        leases[leaseId].cableId = cableId;
        leases[leaseId].lessee = lessee;
        leases[leaseId].fiberType = fiberType;
        leases[leaseId].allocatedGbps = gbps;
        leases[leaseId].annualLeaseRateUSD = rate;
        leases[leaseId].restorationPriority = priority;
        leases[leaseId].totalSLAPenaltiesUSD = FHE.asEuint64(0);
        leases[leaseId].leaseStart = block.timestamp;
        leases[leaseId].leaseEnd = block.timestamp + durationDays * 1 days;
        leases[leaseId].active = true;
        _totalLeaseRevenueUSD = FHE.add(_totalLeaseRevenueUSD, rate);
        FHE.allowThis(leases[leaseId].allocatedGbps); FHE.allow(leases[leaseId].allocatedGbps, lessee);
        FHE.allowThis(leases[leaseId].annualLeaseRateUSD); FHE.allow(leases[leaseId].annualLeaseRateUSD, lessee); FHE.allow(leases[leaseId].annualLeaseRateUSD, cs.operator);
        FHE.allowThis(leases[leaseId].restorationPriority); FHE.allow(leases[leaseId].restorationPriority, lessee);
        FHE.allowThis(leases[leaseId].totalSLAPenaltiesUSD); FHE.allow(leases[leaseId].totalSLAPenaltiesUSD, lessee);
        FHE.allowThis(cs.leasedCapacityGbps); FHE.allow(cs.leasedCapacityGbps, cs.operator);
        FHE.allowThis(_totalLeaseRevenueUSD);
        emit LeaseCreated(leaseId, cableId, lessee);
    }

    function applySLAPenalty(
        uint256 leaseId,
        externalEuint64 encPenalty, bytes calldata proof
    ) external onlyBroker {
        CapacityLease storage l = leases[leaseId];
        euint64 penalty = FHE.fromExternal(encPenalty, proof);
        l.totalSLAPenaltiesUSD = FHE.add(l.totalSLAPenaltiesUSD, penalty);
        _totalPenaltiesPaidUSD = FHE.add(_totalPenaltiesPaidUSD, penalty);
        FHE.allowThis(l.totalSLAPenaltiesUSD); FHE.allow(l.totalSLAPenaltiesUSD, l.lessee);
        FHE.allowThis(_totalPenaltiesPaidUSD);
        emit SLAPenaltyApplied(leaseId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalLeaseRevenueUSD, viewer);
        FHE.allow(_totalPenaltiesPaidUSD, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}