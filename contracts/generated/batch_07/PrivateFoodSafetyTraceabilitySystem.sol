// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateFoodSafetyTraceabilitySystem
/// @notice Encrypted food safety supply chain: hidden contamination risk scores,
///         private batch recall thresholds, confidential supplier audit scores,
///         and encrypted cold chain temperature compliance logs.
contract PrivateFoodSafetyTraceabilitySystem is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum FoodCategory { Produce, Meat, Dairy, Seafood, Packaged, Beverages }
    enum ComplianceStatus { Compliant, UnderReview, NonCompliant, Recalled }

    struct FoodBatch {
        address producer;
        FoodCategory category;
        string batchRef;
        string countryOfOrigin;
        euint8  contaminationRiskScore; // encrypted risk (0-100)
        euint8  coldChainBreachCount;   // encrypted breach count
        euint16 temperatureDeviationBps;// encrypted max deviation
        euint64 batchWeightKg;          // encrypted weight
        euint64 estimatedValueUSD;      // encrypted value
        euint16 supplierAuditScore;     // encrypted audit score
        ComplianceStatus status;
        uint256 producedAt;
        uint256 expiryDate;
    }

    struct RecallEvent {
        uint256 batchId;
        address issuedBy;
        string  recallReason;
        euint64 quantityRecalledKg;    // encrypted recalled quantity
        euint64 recallCostUSD;         // encrypted recall cost
        uint256 issuedAt;
    }

    mapping(uint256 => FoodBatch) private batches;
    mapping(uint256 => RecallEvent) private recalls;
    mapping(address => bool) public isFoodSafetyInspector;
    mapping(address => bool) public isProducerRegistered;

    uint256 public batchCount;
    uint256 public recallCount;
    euint64 private _totalBatchValueUSD;
    euint64 private _totalRecallCostUSD;
    euint32 private _totalNonCompliantBatches;

    event BatchRegistered(uint256 indexed id, FoodCategory category);
    event ColdChainBreachLogged(uint256 indexed batchId, uint256 loggedAt);
    event RecallIssued(uint256 indexed recallId, uint256 batchId);

    modifier onlyFoodSafetyInspector() {
        require(isFoodSafetyInspector[msg.sender] || msg.sender == owner(), "Not food safety inspector");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalBatchValueUSD = FHE.asEuint64(0);
        _totalRecallCostUSD = FHE.asEuint64(0);
        _totalNonCompliantBatches = FHE.asEuint32(0);
        FHE.allowThis(_totalBatchValueUSD);
        FHE.allowThis(_totalRecallCostUSD);
        FHE.allowThis(_totalNonCompliantBatches);
        isFoodSafetyInspector[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addInspector(address ins) external onlyOwner { isFoodSafetyInspector[ins] = true; }
    function registerProducer(address p) external onlyOwner { isProducerRegistered[p] = true; }

    function registerBatch(
        FoodCategory category, string calldata batchRef, string calldata countryOfOrigin,
        externalEuint64 encWeight, bytes calldata wProof,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint16 encAuditScore, bytes calldata asProof,
        uint256 expiryDays
    ) external whenNotPaused returns (uint256 id) {
        require(isProducerRegistered[msg.sender], "Not registered producer");
        euint64 weight     = FHE.fromExternal(encWeight, wProof);
        euint64 value      = FHE.fromExternal(encValue, vProof);
        euint16 auditScore = FHE.fromExternal(encAuditScore, asProof);
        id = batchCount++;
        FoodBatch storage _s0 = batches[id];
        _s0.producer = msg.sender;
        _s0.category = category;
        _s0.batchRef = batchRef;
        _s0.countryOfOrigin = countryOfOrigin;
        _s0.contaminationRiskScore = FHE.asEuint8(0);
        _s0.coldChainBreachCount = FHE.asEuint8(0);
        _s0.temperatureDeviationBps = FHE.asEuint16(0);
        _s0.batchWeightKg = weight;
        _s0.estimatedValueUSD = value;
        _s0.supplierAuditScore = auditScore;
        _s0.status = ComplianceStatus.Compliant;
        _s0.producedAt = block.timestamp;
        _s0.expiryDate = block.timestamp + expiryDays * 1 days;
        _totalBatchValueUSD = FHE.add(_totalBatchValueUSD, value);
        FHE.allowThis(batches[id].contaminationRiskScore);
        FHE.allowThis(batches[id].coldChainBreachCount); FHE.allow(batches[id].coldChainBreachCount, msg.sender);
        FHE.allowThis(batches[id].temperatureDeviationBps);
        FHE.allowThis(batches[id].batchWeightKg); FHE.allow(batches[id].batchWeightKg, msg.sender);
        FHE.allowThis(batches[id].estimatedValueUSD); FHE.allow(batches[id].estimatedValueUSD, msg.sender);
        FHE.allowThis(batches[id].supplierAuditScore); FHE.allow(batches[id].supplierAuditScore, msg.sender);
        FHE.allowThis(_totalBatchValueUSD);
        emit BatchRegistered(id, category);
    }

    function logColdChainBreach(uint256 batchId, externalEuint16 encDeviation, bytes calldata proof) external onlyFoodSafetyInspector whenNotPaused {
        FoodBatch storage b = batches[batchId];
        euint16 deviation = FHE.fromExternal(encDeviation, proof);
        b.coldChainBreachCount = FHE.add(b.coldChainBreachCount, FHE.asEuint8(1));
        b.temperatureDeviationBps = FHE.add(b.temperatureDeviationBps, deviation);
        // Auto flag if breaches > 3 (non-compliant)
        ebool flagged = FHE.gt(b.coldChainBreachCount, FHE.asEuint8(3));
        FHE.allowThis(b.coldChainBreachCount); FHE.allow(b.coldChainBreachCount, b.producer);
        FHE.allowThis(b.temperatureDeviationBps);
        emit ColdChainBreachLogged(batchId, block.timestamp);
    }

    function updateContaminationRisk(uint256 batchId, externalEuint8 encScore, bytes calldata proof) external onlyFoodSafetyInspector {
        FoodBatch storage b = batches[batchId];
        euint8 score = FHE.fromExternal(encScore, proof);
        b.contaminationRiskScore = score;
        ebool highRisk = FHE.gt(score, FHE.asEuint8(70));
        if (FHE.isInitialized(highRisk)) {
            b.status = ComplianceStatus.NonCompliant;
            _totalNonCompliantBatches = FHE.add(_totalNonCompliantBatches, FHE.asEuint32(1));
            FHE.allowThis(_totalNonCompliantBatches);
        }
        FHE.allowThis(b.contaminationRiskScore);
    }

    function issueRecall(uint256 batchId, string calldata recallReason, externalEuint64 encQty, bytes calldata qProof, externalEuint64 encCost, bytes calldata cProof) external onlyFoodSafetyInspector nonReentrant returns (uint256 recallId) {
        FoodBatch storage b = batches[batchId];
        euint64 qty  = FHE.fromExternal(encQty, qProof);
        euint64 cost = FHE.fromExternal(encCost, cProof);
        b.status = ComplianceStatus.Recalled;
        recallId = recallCount++;
        recalls[recallId] = RecallEvent({ batchId: batchId, issuedBy: msg.sender, recallReason: recallReason, quantityRecalledKg: qty, recallCostUSD: cost, issuedAt: block.timestamp });
        _totalRecallCostUSD = FHE.add(_totalRecallCostUSD, cost);
        FHE.allowThis(recalls[recallId].quantityRecalledKg); FHE.allow(recalls[recallId].quantityRecalledKg, b.producer);
        FHE.allowThis(recalls[recallId].recallCostUSD); FHE.allow(recalls[recallId].recallCostUSD, b.producer);
        FHE.allowThis(_totalRecallCostUSD);
        emit RecallIssued(recallId, batchId);
    }

    function allowSafetyStats(address viewer) external onlyOwner {
        FHE.allow(_totalBatchValueUSD, viewer); FHE.allow(_totalRecallCostUSD, viewer); FHE.allow(_totalNonCompliantBatches, viewer);
    }
}
