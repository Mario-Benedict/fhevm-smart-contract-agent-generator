// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateFoodSafetyTraceability
/// @notice Farm-to-fork food safety: encrypted contamination test scores, encrypted batch origin hashes,
///         encrypted temperature compliance logs, and confidential recall probability scoring.
contract PrivateFoodSafetyTraceability is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FoodCategory { PRODUCE, MEAT, DAIRY, SEAFOOD, PROCESSED, BEVERAGE }
    enum ContaminantType { BACTERIA, PESTICIDE, ALLERGEN, HEAVY_METAL, MYCOTOXIN }

    struct FoodBatch {
        string batchId;
        FoodCategory category;
        address producer;
        euint64 quantityKg;         // encrypted quantity
        euint8 safetyScore;         // encrypted safety score 0-100
        euint64 temperatureMin;     // encrypted min recorded temp (scaled Celsius * 10)
        euint64 temperatureMax;     // encrypted max recorded temp
        euint8 contaminationRisk;   // encrypted contamination risk 0-100
        euint64 recallProbBps;      // encrypted probability of recall
        uint256 harvestDate;
        uint256 expiryDate;
        bool quarantined;
        bool recalled;
    }

    struct TestResult {
        uint256 batchId;
        ContaminantType contaminant;
        euint8 levelScore;          // encrypted detected level 0-100
        euint64 detectedPpm;        // encrypted concentration in PPM
        euint8 passThreshold;       // encrypted regulatory threshold 0-100
        bool passed;
        uint256 testDate;
        address laboratory;
    }

    struct TemperatureLog {
        uint256 batchId;
        euint64 temperature;        // encrypted temperature reading
        euint64 humidity;           // encrypted humidity
        uint256 timestamp;
        string location;
        bool compliant;
    }

    mapping(uint256 => FoodBatch) private batches;
    mapping(uint256 => TestResult[]) private testResults;
    mapping(uint256 => TemperatureLog[]) private tempLogs;
    uint256 public batchCount;
    euint64 private _totalRecalledKg;
    mapping(address => bool) public isInspector;
    mapping(address => bool) public isLaboratory;
    mapping(address => bool) public isRegulator;

    event BatchRegistered(uint256 indexed id, string batchId, FoodCategory category);
    event TestSubmitted(uint256 indexed batchId, ContaminantType contaminant, bool passed);
    event BatchQuarantined(uint256 indexed batchId);
    event RecallIssued(uint256 indexed batchId);
    event TemperatureLogged(uint256 indexed batchId, string location);

    constructor() Ownable(msg.sender) {
        _totalRecalledKg = FHE.asEuint64(0);
        FHE.allowThis(_totalRecalledKg);
        isInspector[msg.sender] = true;
        isLaboratory[msg.sender] = true;
        isRegulator[msg.sender] = true;
    }

    function addInspector(address i) external onlyOwner { isInspector[i] = true; }
    function addLaboratory(address l) external onlyOwner { isLaboratory[l] = true; }
    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }

    function registerBatch(
        string calldata batchId, FoodCategory category,
        externalEuint64 encQty, bytes calldata qProof,
        externalEuint64 encRecallProb, bytes calldata rpProof,
        uint256 harvestDate, uint256 expiryDate
    ) external returns (uint256 id) {
        euint64 qty = FHE.fromExternal(encQty, qProof);
        euint64 recallProb = FHE.fromExternal(encRecallProb, rpProof);
        id = batchCount++;
        FoodBatch storage _s0 = batches[id];
        _s0.batchId = batchId;
        _s0.category = category;
        _s0.producer = msg.sender;
        _s0.quantityKg = qty;
        _s0.safetyScore = FHE.asEuint8(100);
        _s0.temperatureMin = FHE.asEuint64(99999);
        _s0.temperatureMax = FHE.asEuint64(0);
        _s0.contaminationRisk = FHE.asEuint8(0);
        _s0.recallProbBps = recallProb;
        _s0.harvestDate = harvestDate;
        _s0.expiryDate = expiryDate;
        _s0.quarantined = false;
        _s0.recalled = false;
        FHE.allowThis(batches[id].quantityKg);
        FHE.allowThis(batches[id].safetyScore);
        FHE.allowThis(batches[id].temperatureMin);
        FHE.allowThis(batches[id].temperatureMax);
        FHE.allowThis(batches[id].contaminationRisk);
        FHE.allowThis(batches[id].recallProbBps);
        emit BatchRegistered(id, batchId, category);
    }

    function submitTestResult(
        uint256 batchId, ContaminantType contaminant,
        externalEuint8 encLevel, bytes calldata lProof,
        externalEuint64 encPpm, bytes calldata ppmProof,
        externalEuint8 encThreshold, bytes calldata thProof
    ) external returns (bool passed) {
        require(isLaboratory[msg.sender], "Not lab");
        euint8 level = FHE.fromExternal(encLevel, lProof);
        euint64 ppm = FHE.fromExternal(encPpm, ppmProof);
        euint8 threshold = FHE.fromExternal(encThreshold, thProof);
        ebool passBool = FHE.le(level, threshold);
        testResults[batchId].push(TestResult({
            batchId: batchId, contaminant: contaminant,
            levelScore: level, detectedPpm: ppm,
            passThreshold: threshold, passed: true,
            testDate: block.timestamp, laboratory: msg.sender
        }));
        uint256 idx = testResults[batchId].length - 1;
        FHE.allowThis(testResults[batchId][idx].levelScore);
        FHE.allowThis(testResults[batchId][idx].detectedPpm);
        FHE.allowThis(testResults[batchId][idx].passThreshold);
        // Update batch safety score
        FoodBatch storage batch = batches[batchId];
        ebool failed = FHE.gt(level, threshold);
        euint8 newSafety = FHE.select(failed,
            FHE.sub(batch.safetyScore, FHE.asEuint8(20)),
            batch.safetyScore);
        batch.safetyScore = newSafety;
        batch.contaminationRisk = FHE.select(failed,
            FHE.add(batch.contaminationRisk, FHE.asEuint8(25)),
            batch.contaminationRisk);
        FHE.allowThis(batch.safetyScore);
        FHE.allowThis(batch.contaminationRisk);
        passed = true;
        emit TestSubmitted(batchId, contaminant, true);
    }

    function logTemperature(
        uint256 batchId, string calldata location,
        externalEuint64 encTemp, bytes calldata tProof,
        externalEuint64 encHumidity, bytes calldata hProof
    ) external {
        require(isInspector[msg.sender] || batches[batchId].producer == msg.sender, "Not authorized");
        euint64 temp = FHE.fromExternal(encTemp, tProof);
        euint64 humidity = FHE.fromExternal(encHumidity, hProof);
        // Update min/max
        FoodBatch storage batch = batches[batchId];
        ebool newMin = FHE.lt(temp, batch.temperatureMin);
        batch.temperatureMin = FHE.select(newMin, temp, batch.temperatureMin);
        ebool newMax = FHE.gt(temp, batch.temperatureMax);
        batch.temperatureMax = FHE.select(newMax, temp, batch.temperatureMax);
        // Cold chain compliance: temp should be < 400 (40.0 Celsius for perishables)
        ebool compliant = FHE.le(temp, FHE.asEuint64(400));
        tempLogs[batchId].push(TemperatureLog({
            batchId: batchId, temperature: temp, humidity: humidity,
            timestamp: block.timestamp, location: location, compliant: true
        }));
        uint256 idx = tempLogs[batchId].length - 1;
        FHE.allowThis(tempLogs[batchId][idx].temperature);
        FHE.allowThis(tempLogs[batchId][idx].humidity);
        FHE.allowThis(batch.temperatureMin);
        FHE.allowThis(batch.temperatureMax);
        emit TemperatureLogged(batchId, location);
    }

    function quarantineBatch(uint256 batchId) external {
        require(isRegulator[msg.sender] || isInspector[msg.sender], "Not authorized");
        batches[batchId].quarantined = true;
        emit BatchQuarantined(batchId);
    }

    function issueRecall(uint256 batchId) external {
        require(isRegulator[msg.sender], "Not regulator");
        FoodBatch storage batch = batches[batchId];
        batch.recalled = true;
        _totalRecalledKg = FHE.add(_totalRecalledKg, batch.quantityKg);
        FHE.allowThis(_totalRecalledKg);
        emit RecallIssued(batchId);
    }

    function grantRegulatorView(uint256 batchId, address regulator) external {
        require(isRegulator[msg.sender], "Not regulator");
        FHE.allow(batches[batchId].safetyScore, regulator);
        FHE.allow(batches[batchId].contaminationRisk, regulator);
        FHE.allow(batches[batchId].recallProbBps, regulator);
        FHE.allow(batches[batchId].quantityKg, regulator);
    }
}
