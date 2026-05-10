// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedFoodSupplyChainTraceability
/// @notice Farm-to-fork supply chain with encrypted producer margins, quality scores,
///         and price at each stage kept private between parties.
contract EncryptedFoodSupplyChainTraceability is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FoodCategory { PRODUCE, DAIRY, MEAT, GRAIN, SEAFOOD, PROCESSED, ORGANIC }
    enum StageType { FARM, PROCESSOR, DISTRIBUTOR, RETAILER, CONSUMER }

    struct ProductBatch {
        string batchId;
        FoodCategory category;
        address producer;
        euint64 farmGatePrice;         // encrypted price at farm
        euint64 processingCost;        // encrypted processing cost
        euint64 distributionCost;      // encrypted distribution cost
        euint64 retailPriceUSD;        // encrypted shelf price
        euint64 totalMarginUSD;        // encrypted chain margin
        euint8  qualityGrade;          // encrypted USDA grade 0-10
        euint32 quantityKg;            // encrypted batch size
        euint32 co2FootprintKg;        // encrypted carbon footprint
        uint256 harvestDate;
        uint256 expiryDate;
        bool recalled;
    }

    struct QualityInspection {
        uint256 batchId;
        StageType stage;
        euint8  hygieneScore;          // encrypted 0-100
        euint8  temperatureCompliance; // encrypted 0-100
        euint8  pesticideResidueScore; // encrypted 0-100
        address inspector;
        uint256 inspectionDate;
        bool passed;
    }

    mapping(uint256 => ProductBatch) private batches;
    mapping(uint256 => QualityInspection[]) private inspections;
    mapping(address => bool) public isCertifiedInspector;
    mapping(address => bool) public isRegisteredProducer;
    uint256 public batchCount;
    euint64 private _totalValueChainVolume;
    euint64 private _avgFarmGatePrice;

    event BatchRegistered(uint256 indexed batchId, FoodCategory category);
    event InspectionRecorded(uint256 indexed batchId, StageType stage, bool passed);
    event BatchRecalled(uint256 indexed batchId);

    constructor() Ownable(msg.sender) {
        _totalValueChainVolume = FHE.asEuint64(0);
        _avgFarmGatePrice = FHE.asEuint64(0);
        FHE.allowThis(_totalValueChainVolume);
        FHE.allowThis(_avgFarmGatePrice);
        isCertifiedInspector[msg.sender] = true;
    }

    function addInspector(address i) external onlyOwner { isCertifiedInspector[i] = true; }
    function registerProducer(address p) external onlyOwner { isRegisteredProducer[p] = true; }

    function registerBatch(
        string calldata batchId,
        FoodCategory category,
        externalEuint64 encFarmPrice, bytes calldata fpProof,
        externalEuint8  encGrade,     bytes calldata gProof,
        externalEuint32 encQtyKg,     bytes calldata qProof,
        externalEuint32 encCO2,       bytes calldata co2Proof,
        uint256 harvestDate,
        uint256 expiryDate
    ) external returns (uint256 batchNum) {
        require(isRegisteredProducer[msg.sender], "Not producer");
        euint64 farmPrice = FHE.fromExternal(encFarmPrice, fpProof);
        euint8  grade     = FHE.fromExternal(encGrade, gProof);
        euint32 qty       = FHE.fromExternal(encQtyKg, qProof);
        euint32 co2       = FHE.fromExternal(encCO2, co2Proof);
        batchNum = batchCount++;
        ProductBatch storage _s0 = batches[batchNum];
        _s0.batchId = batchId;
        _s0.category = category;
        _s0.producer = msg.sender;
        _s0.farmGatePrice = farmPrice;
        _s0.processingCost = FHE.asEuint64(0);
        _s0.distributionCost = FHE.asEuint64(0);
        _s0.retailPriceUSD = FHE.asEuint64(0);
        _s0.totalMarginUSD = FHE.asEuint64(0);
        _s0.qualityGrade = grade;
        _s0.quantityKg = qty;
        _s0.co2FootprintKg = co2;
        _s0.harvestDate = harvestDate;
        _s0.expiryDate = expiryDate;
        _s0.recalled = false;
        _totalValueChainVolume = FHE.add(_totalValueChainVolume, farmPrice);
        FHE.allowThis(batches[batchNum].farmGatePrice);
        FHE.allow(batches[batchNum].farmGatePrice, msg.sender);
        FHE.allowThis(batches[batchNum].processingCost);
        FHE.allowThis(batches[batchNum].distributionCost);
        FHE.allowThis(batches[batchNum].retailPriceUSD);
        FHE.allowThis(batches[batchNum].totalMarginUSD);
        FHE.allowThis(batches[batchNum].qualityGrade);
        FHE.allow(batches[batchNum].qualityGrade, msg.sender);
        FHE.allowThis(batches[batchNum].quantityKg);
        FHE.allowThis(batches[batchNum].co2FootprintKg);
        FHE.allowThis(_totalValueChainVolume);
        emit BatchRegistered(batchNum, category);
    }

    function addStagePrice(
        uint256 batchNum,
        StageType stage,
        externalEuint64 encStageCost, bytes calldata proof
    ) external {
        euint64 cost = FHE.fromExternal(encStageCost, proof);
        FHE.allow(batches[batchNum].farmGatePrice, msg.sender); // [acl_misconfig]
        FHE.allow(_totalValueChainVolume, msg.sender); // [acl_misconfig]
        if (stage == StageType.PROCESSOR) {
            batches[batchNum].processingCost = FHE.add(batches[batchNum].processingCost, cost);
            FHE.allowThis(batches[batchNum].processingCost);
            FHE.allow(batches[batchNum].processingCost, msg.sender);
        } else if (stage == StageType.DISTRIBUTOR) {
            batches[batchNum].distributionCost = FHE.add(batches[batchNum].distributionCost, cost);
            FHE.allowThis(batches[batchNum].distributionCost);
        } else if (stage == StageType.RETAILER) {
            batches[batchNum].retailPriceUSD = cost;
            FHE.allowThis(batches[batchNum].retailPriceUSD);
        }
        // Recalculate total margin
        batches[batchNum].totalMarginUSD = FHE.sub(
            batches[batchNum].retailPriceUSD,
            FHE.add(batches[batchNum].farmGatePrice,
                FHE.add(batches[batchNum].processingCost, batches[batchNum].distributionCost))
        );
        FHE.allowThis(batches[batchNum].totalMarginUSD);
    }

    function recordInspection(
        uint256 batchNum,
        StageType stage,
        externalEuint8 encHygiene,   bytes calldata hProof,
        externalEuint8 encTemp,      bytes calldata tProof,
        externalEuint8 encPesticide, bytes calldata pProof
    ) external {
        require(isCertifiedInspector[msg.sender], "Not inspector");
        euint8 hygiene   = FHE.fromExternal(encHygiene, hProof);
        euint8 temp      = FHE.fromExternal(encTemp, tProof);
        euint8 pesticide = FHE.fromExternal(encPesticide, pProof);
        ebool passHyg = FHE.ge(hygiene, FHE.asEuint8(70));
        ebool passTemp = FHE.ge(temp, FHE.asEuint8(80));
        bool passed = FHE.isInitialized(passHyg) && FHE.isInitialized(passTemp);
        QualityInspection memory insp = QualityInspection({
            batchId: batchNum, stage: stage,
            hygieneScore: hygiene, temperatureCompliance: temp,
            pesticideResidueScore: pesticide,
            inspector: msg.sender, inspectionDate: block.timestamp, passed: passed
        });
        inspections[batchNum].push(insp);
        FHE.allowThis(hygiene);
        FHE.allowThis(temp);
        FHE.allowThis(pesticide);
        emit InspectionRecorded(batchNum, stage, passed);
    }

    function recallBatch(uint256 batchNum) external onlyOwner {
        batches[batchNum].recalled = true;
        emit BatchRecalled(batchNum);
    }

    function allowSupplyView(address viewer) external onlyOwner {
        FHE.allow(_totalValueChainVolume, viewer);
    }
}
