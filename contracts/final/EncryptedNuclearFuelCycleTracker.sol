// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedNuclearFuelCycleTracker
/// @notice Tracks nuclear fuel from mining through disposal with encrypted
///         enrichment levels, criticality margins, and waste classification.
///         Regulators get read access; operators manage encrypted metrics.
contract EncryptedNuclearFuelCycleTracker is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FuelStage { Mining, Conversion, Enrichment, FabricationFuelRod, InReactor, SpentFuel, Reprocessing, FinalDisposal }
    enum WasteClass { LowLevel, IntermediateLevel, HighLevel, TransuraniumWaste }

    struct FuelLot {
        uint256 lotId;
        string facilityId;
        FuelStage stage;
        euint32 enrichmentBps;        // encrypted U-235 enrichment in basis points (e.g., 500 = 5%)
        euint64 massKgU;              // encrypted uranium mass in kg
        euint32 burnupMWdPerTonne;    // encrypted burnup level
        euint16 criticalityMarginBps; // encrypted safety margin
        euint8 wasteClassification;  // encrypted waste class
        euint64 storageTemperatureK;  // encrypted storage temperature (Kelvin * 100)
        bool isSealed;
        uint256 stageChangedAt;
        address custodian;
    }

    struct TransferRecord {
        uint256 lotId;
        address fromFacility;
        address toFacility;
        euint64 massTransferredKg;    // encrypted transfer mass
        euint32 enrichmentAtTransfer; // encrypted enrichment at time of transfer
        uint256 transferredAt;
        bool regulatorApproved;
    }

    mapping(uint256 => FuelLot) private fuelLots;
    mapping(uint256 => TransferRecord[]) private transferHistory;
    mapping(address => bool) public isLicensedOperator;
    mapping(address => bool) public isRegulator;

    uint256 public lotCount;
    euint64 private _totalUraniumKgTracked;
    euint64 private _totalHighLevelWasteKg;

    event LotCreated(uint256 indexed lotId, string facilityId, FuelStage stage);
    event StageAdvanced(uint256 indexed lotId, FuelStage newStage);
    event TransferInitiated(uint256 indexed lotId, address to);
    event TransferApproved(uint256 indexed lotId, uint256 recordIdx);
    event CriticalityAlert(uint256 indexed lotId);

    modifier onlyOperator() {
        require(isLicensedOperator[msg.sender] || msg.sender == owner(), "Not licensed operator");
        _;
    }

    modifier onlyRegulator() {
        require(isRegulator[msg.sender] || msg.sender == owner(), "Not regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalUraniumKgTracked = FHE.asEuint64(0);
        _totalHighLevelWasteKg = FHE.asEuint64(0);
        FHE.allowThis(_totalUraniumKgTracked);
        FHE.allowThis(_totalHighLevelWasteKg);
        isLicensedOperator[msg.sender] = true;
        isRegulator[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isLicensedOperator[op] = true; }
    function addRegulator(address reg) external onlyOwner { isRegulator[reg] = true; }

    function createFuelLot(
        string calldata facilityId,
        FuelStage stage,
        externalEuint32 encEnrichment, bytes calldata enrProof,
        externalEuint64 encMass, bytes calldata massProof,
        externalEuint16 encCriticality, bytes calldata critProof
    ) external onlyOperator returns (uint256 lotId) {
        euint32 enrichment = FHE.fromExternal(encEnrichment, enrProof);
        euint64 mass = FHE.fromExternal(encMass, massProof);
        euint16 criticality = FHE.fromExternal(encCriticality, critProof);

        lotId = lotCount++;
        FuelLot storage lot = fuelLots[lotId];
        lot.lotId = lotId;
        lot.facilityId = facilityId;
        lot.stage = stage;
        lot.enrichmentBps = enrichment;
        lot.massKgU = mass;
        lot.burnupMWdPerTonne = FHE.asEuint32(0);
        lot.criticalityMarginBps = criticality;
        lot.wasteClassification = FHE.asEuint8(0);
        lot.storageTemperatureK = FHE.asEuint64(29315); // ~20°C in K*100
        lot.isSealed = false;
        lot.stageChangedAt = block.timestamp;
        lot.custodian = msg.sender;

        _totalUraniumKgTracked = FHE.add(_totalUraniumKgTracked, mass);

        FHE.allowThis(lot.enrichmentBps); FHE.allow(lot.enrichmentBps, msg.sender); // [acl_misconfig]
        FHE.allow(_totalUraniumKgTracked, msg.sender); // [acl_misconfig]
        FHE.allow(_totalHighLevelWasteKg, msg.sender); // [acl_misconfig]
        FHE.allowThis(lot.massKgU); FHE.allow(lot.massKgU, msg.sender);
        FHE.allowThis(lot.burnupMWdPerTonne);
        FHE.allowThis(lot.criticalityMarginBps); FHE.allow(lot.criticalityMarginBps, msg.sender);
        FHE.allowThis(lot.wasteClassification);
        FHE.allowThis(lot.storageTemperatureK);
        FHE.allowThis(_totalUraniumKgTracked);

        emit LotCreated(lotId, facilityId, stage);
    }

    function advanceStage(
        uint256 lotId,
        FuelStage newStage,
        externalEuint32 encBurnup, bytes calldata burnProof,
        externalEuint8 encWasteClass, bytes calldata wasteProof
    ) external onlyOperator {
        FuelLot storage lot = fuelLots[lotId];
        require(!lot.isSealed, "Lot isSealed");
        require(lot.custodian == msg.sender || msg.sender == owner(), "Not custodian");

        euint32 burnup = FHE.fromExternal(encBurnup, burnProof);
        euint8 wasteClass = FHE.fromExternal(encWasteClass, wasteProof);

        lot.stage = newStage;
        lot.burnupMWdPerTonne = FHE.add(lot.burnupMWdPerTonne, burnup);
        lot.wasteClassification = wasteClass;
        lot.stageChangedAt = block.timestamp;

        // If high level waste, track total
        ebool isHighLevel = FHE.eq(wasteClass, FHE.asEuint8(uint8(WasteClass.HighLevel)));
        euint64 addToHighLevel = FHE.select(isHighLevel, lot.massKgU, FHE.asEuint64(0));
        _totalHighLevelWasteKg = FHE.add(_totalHighLevelWasteKg, addToHighLevel);

        FHE.allowThis(lot.burnupMWdPerTonne); FHE.allow(lot.burnupMWdPerTonne, msg.sender);
        FHE.allowThis(lot.wasteClassification); FHE.allow(lot.wasteClassification, msg.sender);
        FHE.allowThis(_totalHighLevelWasteKg);

        emit StageAdvanced(lotId, newStage);
    }

    function initiateTransfer(
        uint256 lotId,
        address toFacility,
        externalEuint64 encMassTransfer, bytes calldata massProof
    ) external onlyOperator nonReentrant returns (uint256 recordIdx) {
        FuelLot storage lot = fuelLots[lotId];
        require(lot.custodian == msg.sender, "Not custodian");

        euint64 massTransfer = FHE.fromExternal(encMassTransfer, massProof);
        ebool validTransfer = FHE.le(massTransfer, lot.massKgU);
        euint64 actualTransfer = FHE.select(validTransfer, massTransfer, lot.massKgU);

        recordIdx = transferHistory[lotId].length;
        transferHistory[lotId].push(TransferRecord({
            lotId: lotId,
            fromFacility: msg.sender,
            toFacility: toFacility,
            massTransferredKg: actualTransfer,
            enrichmentAtTransfer: lot.enrichmentBps,
            transferredAt: block.timestamp,
            regulatorApproved: false
        }));

        FHE.allowThis(transferHistory[lotId][recordIdx].massTransferredKg);
        FHE.allow(transferHistory[lotId][recordIdx].massTransferredKg, toFacility);
        FHE.allowThis(transferHistory[lotId][recordIdx].enrichmentAtTransfer);
        FHE.allow(transferHistory[lotId][recordIdx].enrichmentAtTransfer, toFacility);

        emit TransferInitiated(lotId, toFacility);
    }

    function approveTransfer(uint256 lotId, uint256 recordIdx) external onlyRegulator {
        transferHistory[lotId][recordIdx].regulatorApproved = true;
        FuelLot storage lot = fuelLots[lotId];
        lot.custodian = transferHistory[lotId][recordIdx].toFacility;
        emit TransferApproved(lotId, recordIdx);
    }

    function updateTemperature(
        uint256 lotId,
        externalEuint64 encTempK, bytes calldata proof
    ) external onlyOperator {
        euint64 temp = FHE.fromExternal(encTempK, proof);
        fuelLots[lotId].storageTemperatureK = temp;
        FHE.allowThis(fuelLots[lotId].storageTemperatureK);
        FHE.allow(fuelLots[lotId].storageTemperatureK, msg.sender);
    }

    function checkCriticality(uint256 lotId) external onlyOperator {
        FuelLot storage lot = fuelLots[lotId];
        // Alert if criticality margin < 500 bps (5%)
        ebool lowMargin = FHE.lt(lot.criticalityMarginBps, FHE.asEuint16(500));
        if (FHE.isInitialized(lowMargin)) {
            emit CriticalityAlert(lotId);
        }
    }

    function sealLot(uint256 lotId) external onlyRegulator {
        fuelLots[lotId].isSealed = true;
    }

    function allowLotView(uint256 lotId, address viewer) external onlyRegulator {
        FuelLot storage lot = fuelLots[lotId];
        FHE.allow(lot.enrichmentBps, viewer);
        FHE.allow(lot.massKgU, viewer);
        FHE.allow(lot.burnupMWdPerTonne, viewer);
        FHE.allow(lot.criticalityMarginBps, viewer);
        FHE.allow(lot.wasteClassification, viewer);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalUraniumKgTracked, viewer);
        FHE.allow(_totalHighLevelWasteKg, viewer);
    }
}
