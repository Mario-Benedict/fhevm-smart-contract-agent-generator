// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAircraftMaintenanceEscrow
/// @notice MRO (Maintenance, Repair, Overhaul) escrow for commercial aircraft.
///         Encrypted labor costs, parts pricing, and AOG (Aircraft on Ground)
///         penalties ensure confidential maintenance bidding and settlement.
contract PrivateAircraftMaintenanceEscrow is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MaintenanceType { ACheck, BCheck, CCheck, DCheck, EngineShop, AvionicsOverhaul, PaintingReskin }
    enum EscrowStatus { Created, Funded, WorkStarted, WorkCompleted, Disputed, Released, Refunded }

    struct MaintenanceEscrow {
        uint256 escrowId;
        address airline;
        address mroProvider;
        string tailNumber;
        MaintenanceType maintenanceType;
        euint64 agreedLaborCostUSD;       // encrypted labor cost
        euint64 agreedPartsCostUSD;       // encrypted parts cost
        euint64 aogPenaltyPerDayUSD;      // encrypted penalty per day AOG
        euint64 totalEscrowAmountUSD;     // encrypted total held
        euint64 aogPenaltyAccruedUSD;     // encrypted accrued penalties
        euint32 estimatedCompletionDuration; // duration in blocks/time
        EscrowStatus status;
        uint256 workStartedAt;
        uint256 workCompletedAt;
        uint256 fundedAt;
    }

    struct QualityInspection {
        uint256 escrowId;
        euint16 structuralScore;          // encrypted 0-100
        euint16 avionicsScore;            // encrypted 0-100
        euint16 engineScore;              // encrypted 0-100
        euint16 overallScore;             // encrypted composite
        bool approved;
        address inspector;
        uint256 inspectedAt;
    }

    mapping(uint256 => MaintenanceEscrow) private escrows;
    mapping(uint256 => QualityInspection) private inspections;
    mapping(address => bool) public isApprovedMRO;
    mapping(address => bool) public isAviationInspector;
    mapping(address => bool) public isAirline;

    uint256 public escrowCount;
    euint64 private _totalEscrowValue;
    euint64 private _totalAOGPenaltiesCollected;
    euint64 private _totalMRORevenue;

    event EscrowCreated(uint256 indexed escrowId, string tailNumber, MaintenanceType maintenanceType);
    event EscrowFunded(uint256 indexed escrowId);
    event WorkStarted(uint256 indexed escrowId);
    event WorkCompleted(uint256 indexed escrowId);
    event EscrowReleased(uint256 indexed escrowId);
    event DisputeRaised(uint256 indexed escrowId, address by);

    modifier onlyInspector() {
        require(isAviationInspector[msg.sender] || msg.sender == owner(), "Not aviation inspector");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalEscrowValue = FHE.asEuint64(0);
        _totalAOGPenaltiesCollected = FHE.asEuint64(0);
        _totalMRORevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalEscrowValue);
        FHE.allowThis(_totalAOGPenaltiesCollected);
        FHE.allowThis(_totalMRORevenue);
        isAviationInspector[msg.sender] = true;
    }

    function addMRO(address mro) external onlyOwner { isApprovedMRO[mro] = true; }
    function addInspector(address insp) external onlyOwner { isAviationInspector[insp] = true; }
    function addAirline(address airline) external onlyOwner { isAirline[airline] = true; }

    function createEscrow(
        address mroProvider,
        string calldata tailNumber,
        MaintenanceType maintenanceType,
        externalEuint64 encLaborCost, bytes calldata laborProof,
        externalEuint64 encPartsCost, bytes calldata partsProof,
        externalEuint64 encAOGPenalty, bytes calldata aogProof,
        uint32 estimatedDuration
    ) external returns (uint256 escrowId) {
        require(isAirline[msg.sender], "Not registered airline");
        require(isApprovedMRO[mroProvider], "Not approved MRO");

        euint64 laborCost = FHE.fromExternal(encLaborCost, laborProof);
        euint64 partsCost = FHE.fromExternal(encPartsCost, partsProof);
        euint64 aogPenalty = FHE.fromExternal(encAOGPenalty, aogProof);
        euint64 totalAmount = FHE.add(laborCost, partsCost);

        escrowId = escrowCount++;
        MaintenanceEscrow storage e = escrows[escrowId];
        e.escrowId = escrowId;
        e.airline = msg.sender;
        e.mroProvider = mroProvider;
        e.tailNumber = tailNumber;
        e.maintenanceType = maintenanceType;
        e.agreedLaborCostUSD = laborCost;
        e.agreedPartsCostUSD = partsCost;
        e.aogPenaltyPerDayUSD = aogPenalty;
        e.totalEscrowAmountUSD = totalAmount;
        e.aogPenaltyAccruedUSD = FHE.asEuint64(0);
        e.estimatedCompletionDuration = FHE.asEuint32(estimatedDuration);
        FHE.allowThis(e.estimatedCompletionDuration);
        e.status = EscrowStatus.Created;

        FHE.allowThis(e.agreedLaborCostUSD); FHE.allow(e.agreedLaborCostUSD, msg.sender); FHE.allow(e.agreedLaborCostUSD, mroProvider);
        FHE.allowThis(e.agreedPartsCostUSD); FHE.allow(e.agreedPartsCostUSD, msg.sender); FHE.allow(e.agreedPartsCostUSD, mroProvider);
        FHE.allowThis(e.aogPenaltyPerDayUSD);
        FHE.allowThis(e.totalEscrowAmountUSD); FHE.allow(e.totalEscrowAmountUSD, msg.sender);
        FHE.allowThis(e.aogPenaltyAccruedUSD);

        emit EscrowCreated(escrowId, tailNumber, maintenanceType);
    }

    function fundEscrow(uint256 escrowId) external {
        MaintenanceEscrow storage e = escrows[escrowId];
        require(e.airline == msg.sender, "Not airline");
        require(e.status == EscrowStatus.Created, "Wrong status");
        e.status = EscrowStatus.Funded;
        e.fundedAt = block.timestamp;
        _totalEscrowValue = FHE.add(_totalEscrowValue, e.totalEscrowAmountUSD);
        FHE.allowThis(_totalEscrowValue);
        emit EscrowFunded(escrowId);
    }

    function startWork(uint256 escrowId) external {
        MaintenanceEscrow storage e = escrows[escrowId];
        require(e.mroProvider == msg.sender, "Not MRO provider");
        require(e.status == EscrowStatus.Funded, "Not funded");
        e.status = EscrowStatus.WorkStarted;
        e.workStartedAt = block.timestamp;
        emit WorkStarted(escrowId);
    }

    function completeWork(uint256 escrowId) external {
        MaintenanceEscrow storage e = escrows[escrowId];
        require(e.mroProvider == msg.sender, "Not MRO provider");
        require(e.status == EscrowStatus.WorkStarted, "Work not started");
        e.status = EscrowStatus.WorkCompleted;
        e.workCompletedAt = block.timestamp;
        emit WorkCompleted(escrowId);
    }

    function submitInspection(
        uint256 escrowId,
        externalEuint16 encStructural, bytes calldata structProof,
        externalEuint16 encAvionics, bytes calldata avioProof,
        externalEuint16 encEngine, bytes calldata engProof
    ) external onlyInspector {
        MaintenanceEscrow storage e = escrows[escrowId];
        require(e.status == EscrowStatus.WorkCompleted, "Work not completed");

        euint16 structural = FHE.fromExternal(encStructural, structProof);
        euint16 avionics = FHE.fromExternal(encAvionics, avioProof);
        euint16 engine = FHE.fromExternal(encEngine, engProof);
        euint16 overall = FHE.div(FHE.add(FHE.add(structural, avionics), engine), 3);

        QualityInspection storage insp = inspections[escrowId];
        insp.escrowId = escrowId;
        insp.structuralScore = structural;
        insp.avionicsScore = avionics;
        insp.engineScore = engine;
        insp.overallScore = overall;
        insp.inspector = msg.sender;
        insp.inspectedAt = block.timestamp;
        insp.approved = true; // simplified - approve if all scores submitted

        FHE.allowThis(insp.structuralScore); FHE.allow(insp.structuralScore, e.airline);
        FHE.allowThis(insp.avionicsScore); FHE.allow(insp.avionicsScore, e.airline);
        FHE.allowThis(insp.engineScore); FHE.allow(insp.engineScore, e.airline);
        FHE.allowThis(insp.overallScore); FHE.allow(insp.overallScore, e.airline); FHE.allow(insp.overallScore, e.mroProvider);
    }

    function releaseEscrow(
        uint256 escrowId,
        externalEuint64 encAOGPenalty, bytes calldata proof
    ) external onlyInspector nonReentrant {
        MaintenanceEscrow storage e = escrows[escrowId];
        require(e.status == EscrowStatus.WorkCompleted, "Not completed");
        require(inspections[escrowId].approved, "Not inspected");

        euint64 aogPenalty = FHE.fromExternal(encAOGPenalty, proof);
        e.aogPenaltyAccruedUSD = aogPenalty;
        euint64 mroPayment = FHE.sub(e.totalEscrowAmountUSD, aogPenalty);

        e.status = EscrowStatus.Released;
        _totalEscrowValue = FHE.sub(_totalEscrowValue, e.totalEscrowAmountUSD);
        _totalAOGPenaltiesCollected = FHE.add(_totalAOGPenaltiesCollected, aogPenalty);
        _totalMRORevenue = FHE.add(_totalMRORevenue, mroPayment);

        FHE.allowThis(e.aogPenaltyAccruedUSD); FHE.allow(e.aogPenaltyAccruedUSD, e.airline);
        FHE.allow(mroPayment, e.mroProvider);
        FHE.allowThis(_totalEscrowValue); FHE.allowThis(_totalAOGPenaltiesCollected); FHE.allowThis(_totalMRORevenue);

        emit EscrowReleased(escrowId);
    }

    function raiseDispute(uint256 escrowId) external {
        MaintenanceEscrow storage e = escrows[escrowId];
        require(e.airline == msg.sender || e.mroProvider == msg.sender, "Not party");
        require(e.status == EscrowStatus.WorkCompleted || e.status == EscrowStatus.WorkStarted, "Cannot dispute");
        e.status = EscrowStatus.Disputed;
        emit DisputeRaised(escrowId, msg.sender);
    }

    function allowEscrowStats(address viewer) external onlyOwner {
        FHE.allow(_totalEscrowValue, viewer);
        FHE.allow(_totalAOGPenaltiesCollected, viewer);
        FHE.allow(_totalMRORevenue, viewer);
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