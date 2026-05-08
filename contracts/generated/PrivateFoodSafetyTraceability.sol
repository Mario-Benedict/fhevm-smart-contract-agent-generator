// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateFoodSafetyTraceability
/// @notice Farm-to-table traceability: encrypted batch temperatures, encrypted
///         contamination scores, private recall triggers, and retailer access gating.
contract PrivateFoodSafetyTraceability is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FoodCategory { FreshProduce, Meat, Dairy, Seafood, Grains, Processed }
    enum BatchStatus { Harvested, Processing, PackagingQC, InTransit, Distributed, Recalled }

    struct FoodBatch {
        string lotNumber;
        FoodCategory category;
        address producer;
        euint8  contaminationScore;    // encrypted 0=safe,100=dangerous
        euint16 temperatureMin;        // encrypted min temp observed (C * 10)
        euint16 temperatureMax;        // encrypted max temp observed (C * 10)
        euint32 weightKg;              // encrypted total weight
        euint8  qualityGrade;          // encrypted A/B/C grade (1/2/3)
        uint256 producedAt;
        BatchStatus status;
        bool recallIssued;
    }

    struct SupplyChainEvent {
        uint256 batchId;
        string eventType;              // "HARVEST","PROCESS","PACK","SHIP","RECEIVE"
        address actor;
        euint16 temperature;           // encrypted temp at event
        uint256 timestamp;
    }

    mapping(uint256 => FoodBatch) private batches;
    mapping(uint256 => SupplyChainEvent[]) private batchEvents;
    mapping(address => bool) public isInspector;
    mapping(address => bool) public isRetailer;
    mapping(address => bool) public isProducer;
    uint256 public batchCount;
    euint8 private _recallThreshold;   // encrypted contamination score above which recall triggered
    euint32 private _totalBatchesRecalled;

    event BatchCreated(uint256 indexed id, string lot, FoodCategory category);
    event QualityEventLogged(uint256 indexed batchId, string eventType);
    event RecallIssued(uint256 indexed batchId, string lot);
    event BatchCleared(uint256 indexed batchId);

    modifier onlyInspector() {
        require(isInspector[msg.sender] || msg.sender == owner(), "Not inspector");
        _;
    }

    constructor(externalEuint8 encRecallThreshold, bytes memory proof) Ownable(msg.sender) {
        _recallThreshold = FHE.fromExternal(encRecallThreshold, proof);
        _totalBatchesRecalled = FHE.asEuint32(0);
        FHE.allowThis(_recallThreshold);
        FHE.allowThis(_totalBatchesRecalled);
        isInspector[msg.sender] = true;
    }

    function addInspector(address i) external onlyOwner { isInspector[i] = true; }
    function addRetailer(address r) external onlyOwner { isRetailer[r] = true; }
    function addProducer(address p) external onlyOwner { isProducer[p] = true; }

    function createBatch(
        string calldata lot, FoodCategory category,
        externalEuint32 encWeight, bytes calldata wPf,
        externalEuint8 encGrade, bytes calldata gPf,
        externalEuint16 encTempMin, bytes calldata tMinPf,
        externalEuint16 encTempMax, bytes calldata tMaxPf
    ) external returns (uint256 id) {
        require(isProducer[msg.sender], "Not producer");
        euint32 weight = FHE.fromExternal(encWeight, wPf);
        euint8 grade = FHE.fromExternal(encGrade, gPf);
        euint16 tempMin = FHE.fromExternal(encTempMin, tMinPf);
        euint16 tempMax = FHE.fromExternal(encTempMax, tMaxPf);
        id = batchCount++;
        batches[id] = FoodBatch({
            lotNumber: lot, category: category, producer: msg.sender,
            contaminationScore: FHE.asEuint8(0),
            temperatureMin: tempMin, temperatureMax: tempMax,
            weightKg: weight, qualityGrade: grade,
            producedAt: block.timestamp, status: BatchStatus.Harvested, recallIssued: false
        });
        FHE.allowThis(batches[id].contaminationScore);
        FHE.allowThis(batches[id].temperatureMin);
        FHE.allow(batches[id].temperatureMin, msg.sender);
        FHE.allowThis(batches[id].temperatureMax);
        FHE.allow(batches[id].temperatureMax, msg.sender);
        FHE.allowThis(batches[id].weightKg);
        FHE.allow(batches[id].weightKg, msg.sender);
        FHE.allowThis(batches[id].qualityGrade);
        FHE.allow(batches[id].qualityGrade, msg.sender);
        emit BatchCreated(id, lot, category);
    }

    function logSupplyEvent(
        uint256 batchId, string calldata eventType, BatchStatus newStatus,
        externalEuint16 encTemp, bytes calldata proof
    ) external {
        require(isProducer[msg.sender] || isRetailer[msg.sender] || isInspector[msg.sender], "Unauthorized");
        euint16 temp = FHE.fromExternal(encTemp, proof);
        batchEvents[batchId].push(SupplyChainEvent({
            batchId: batchId, eventType: eventType, actor: msg.sender,
            temperature: temp, timestamp: block.timestamp
        }));
        batches[batchId].status = newStatus;
        FHE.allowThis(batchEvents[batchId][batchEvents[batchId].length - 1].temperature);
        emit QualityEventLogged(batchId, eventType);
    }

    function recordContamination(
        uint256 batchId,
        externalEuint8 encScore, bytes calldata proof
    ) external onlyInspector {
        euint8 score = FHE.fromExternal(encScore, proof);
        batches[batchId].contaminationScore = score;
        FHE.allowThis(batches[batchId].contaminationScore);
        FHE.allow(batches[batchId].contaminationScore, batches[batchId].producer);
        // Auto-recall if above threshold
        ebool needsRecall = FHE.ge(score, _recallThreshold);
        if (FHE.isInitialized(needsRecall) && !batches[batchId].recallIssued) {
            batches[batchId].recallIssued = true;
            batches[batchId].status = BatchStatus.Recalled;
            _totalBatchesRecalled = FHE.add(_totalBatchesRecalled, FHE.asEuint32(1));
            FHE.allowThis(_totalBatchesRecalled);
            emit RecallIssued(batchId, batches[batchId].lotNumber);
        }
    }

    function clearBatch(uint256 batchId) external onlyInspector {
        batches[batchId].recallIssued = false;
        batches[batchId].contaminationScore = FHE.asEuint8(0);
        FHE.allowThis(batches[batchId].contaminationScore);
        emit BatchCleared(batchId);
    }

    function allowBatchDetails(uint256 batchId, address viewer) external {
        FoodBatch storage b = batches[batchId];
        require(msg.sender == b.producer || isInspector[msg.sender] || isRetailer[msg.sender], "Unauthorized");
        FHE.allow(b.contaminationScore, viewer);
        FHE.allow(b.temperatureMin, viewer);
        FHE.allow(b.temperatureMax, viewer);
        FHE.allow(b.qualityGrade, viewer);
    }

    function allowSafetyStats(address viewer) external onlyOwner {
        FHE.allow(_totalBatchesRecalled, viewer);
    }
}
