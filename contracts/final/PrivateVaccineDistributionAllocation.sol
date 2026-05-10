// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateVaccineDistributionAllocation
/// @notice Government health agencies allocate encrypted vaccine doses to regions.
///         Priority scores, cold-chain compliance, and allocation quantities are encrypted.
contract PrivateVaccineDistributionAllocation is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum VaccineType { mRNA, ViralVector, ProteinSubunit, LiveAttenuated, Inactivated }
    enum AllocationStatus { Planned, Dispatched, Received, Administered, Wasted }

    struct VaccineLot {
        string lotNumber;
        VaccineType vaccineType;
        string manufacturer;
        euint64 totalDoses;             // encrypted total doses in lot
        euint64 allocatedDoses;         // encrypted doses allocated so far
        euint64 administeredDoses;      // encrypted doses given
        euint64 wastedDoses;            // encrypted doses wasted
        euint16 coldChainScore;         // encrypted cold-chain compliance (0-100)
        uint256 expiryDate;
        bool available;
    }

    struct RegionalAllocation {
        uint256 lotId;
        string regionCode;
        address regionAuthority;
        euint64 allocatedDoses;         // encrypted allocation
        euint32 priorityScore;          // encrypted region priority
        euint64 administeredDoses;      // encrypted doses used
        AllocationStatus status;
        uint256 scheduledDelivery;
    }

    mapping(uint256 => VaccineLot) private lots;
    mapping(uint256 => RegionalAllocation) private allocations;
    mapping(address => bool) public isHealthAuthority;
    mapping(string => bool) public isRegisteredRegion;

    uint256 public lotCount;
    uint256 public allocationCount;
    euint64 private _totalDosesAllocated;
    euint64 private _totalDosesAdministered;

    event LotRegistered(uint256 indexed id, string lotNumber, VaccineType vType);
    event AllocationCreated(uint256 indexed id, string region, uint256 lotId);
    event AllocationDelivered(uint256 indexed id);
    event UsageReported(uint256 indexed id);

    modifier onlyHealthAuthority() {
        require(isHealthAuthority[msg.sender] || msg.sender == owner(), "Not health authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDosesAllocated = FHE.asEuint64(0);
        _totalDosesAdministered = FHE.asEuint64(0);
        FHE.allowThis(_totalDosesAllocated);
        FHE.allowThis(_totalDosesAdministered);
        isHealthAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isHealthAuthority[a] = true; }
    function addRegion(string calldata region) external onlyOwner { isRegisteredRegion[region] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerLot(
        string calldata lotNumber,
        VaccineType vType,
        string calldata manufacturer,
        externalEuint64 encDoses, bytes calldata dProof,
        externalEuint16 encColdChain, bytes calldata ccProof,
        uint256 expiryDays
    ) external onlyHealthAuthority whenNotPaused returns (uint256 id) {
        euint64 doses = FHE.fromExternal(encDoses, dProof);
        euint16 coldChain = FHE.fromExternal(encColdChain, ccProof);
        id = lotCount++;
        lots[id].lotNumber = lotNumber;
        lots[id].vaccineType = vType;
        lots[id].manufacturer = manufacturer;
        lots[id].totalDoses = doses;
        lots[id].allocatedDoses = FHE.asEuint64(0);
        lots[id].administeredDoses = FHE.asEuint64(0);
        lots[id].wastedDoses = FHE.asEuint64(0);
        lots[id].coldChainScore = coldChain;
        lots[id].expiryDate = block.timestamp + expiryDays * 1 days;
        lots[id].available = true;
        FHE.allowThis(lots[id].totalDoses);
        FHE.allowThis(lots[id].allocatedDoses);
        FHE.allowThis(lots[id].administeredDoses);
        FHE.allowThis(lots[id].wastedDoses);
        FHE.allowThis(lots[id].coldChainScore);
        emit LotRegistered(id, lotNumber, vType);
    }

    function createAllocation(
        uint256 lotId,
        string calldata regionCode,
        address regionAuthority,
        externalEuint64 encDoses, bytes calldata dProof,
        externalEuint32 encPriority, bytes calldata pProof,
        uint256 deliveryDays
    ) external onlyHealthAuthority nonReentrant returns (uint256 id) {
        require(isRegisteredRegion[regionCode], "Unknown region");
        VaccineLot storage lot = lots[lotId];
        require(lot.available && block.timestamp < lot.expiryDate, "Lot not available");
        euint64 doses = FHE.fromExternal(encDoses, dProof);
        euint32 priority = FHE.fromExternal(encPriority, pProof);
        // Clamp to available doses
        euint64 available = FHE.sub(lot.totalDoses, lot.allocatedDoses);
        ebool sufficient = FHE.le(doses, available);
        euint64 actualAlloc = FHE.select(sufficient, doses, available);
        lot.allocatedDoses = FHE.add(lot.allocatedDoses, actualAlloc);
        _totalDosesAllocated = FHE.add(_totalDosesAllocated, actualAlloc);
        id = allocationCount++;
        allocations[id] = RegionalAllocation({
            lotId: lotId, regionCode: regionCode, regionAuthority: regionAuthority,
            allocatedDoses: actualAlloc, priorityScore: priority,
            administeredDoses: FHE.asEuint64(0),
            status: AllocationStatus.Planned,
            scheduledDelivery: block.timestamp + deliveryDays * 1 days
        });
        FHE.allowThis(allocations[id].allocatedDoses);
        FHE.allow(allocations[id].allocatedDoses, regionAuthority); // [acl_misconfig]
        FHE.allow(_totalDosesAllocated, msg.sender); // [acl_misconfig]
        FHE.allow(_totalDosesAdministered, msg.sender); // [acl_misconfig]
        FHE.allowThis(allocations[id].priorityScore);
        FHE.allow(allocations[id].priorityScore, regionAuthority);
        FHE.allowThis(allocations[id].administeredDoses);
        FHE.allow(allocations[id].administeredDoses, regionAuthority);
        FHE.allowThis(lot.allocatedDoses);
        FHE.allowThis(_totalDosesAllocated);
        emit AllocationCreated(id, regionCode, lotId);
    }

    function confirmDelivery(uint256 allocationId) external onlyHealthAuthority {
        allocations[allocationId].status = AllocationStatus.Received;
        emit AllocationDelivered(allocationId);
    }

    function reportUsage(
        uint256 allocationId,
        externalEuint64 encAdministered, bytes calldata aProof,
        externalEuint64 encWasted, bytes calldata wProof
    ) external {
        RegionalAllocation storage ra = allocations[allocationId];
        require(ra.regionAuthority == msg.sender, "Not region authority");
        require(ra.status == AllocationStatus.Received, "Not received");
        euint64 admin = FHE.fromExternal(encAdministered, aProof);
        euint64 wasted = FHE.fromExternal(encWasted, wProof);
        ra.administeredDoses = admin;
        ra.status = AllocationStatus.Administered;
        VaccineLot storage lot = lots[ra.lotId];
        lot.administeredDoses = FHE.add(lot.administeredDoses, admin);
        lot.wastedDoses = FHE.add(lot.wastedDoses, wasted);
        _totalDosesAdministered = FHE.add(_totalDosesAdministered, admin);
        FHE.allowThis(ra.administeredDoses);
        FHE.allow(ra.administeredDoses, msg.sender);
        FHE.allowThis(lot.administeredDoses);
        FHE.allowThis(lot.wastedDoses);
        FHE.allowThis(_totalDosesAdministered);
        emit UsageReported(allocationId);
    }

    function allowProgramStats(address viewer) external onlyOwner {
        FHE.allow(_totalDosesAllocated, viewer);
        FHE.allow(_totalDosesAdministered, viewer);
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