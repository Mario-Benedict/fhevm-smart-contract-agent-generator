// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateMeatPackingSupplyChain
/// @notice Encrypted meat packing supply chain traceability: hidden livestock purchase prices,
///         confidential yield efficiencies, private cold chain compliance, and encrypted
///         contamination recall risk scores for food safety authorities.
contract PrivateMeatPackingSupplyChain is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum MeatType { Beef, Pork, Lamb, Poultry, Veal, Bison }
    enum BatchStatus { Slaughter, Processing, QualityCheck, Packaged, Shipped, Recalled }

    struct LivestockPurchase {
        address farmer;
        address meatPacker;
        MeatType meatType;
        euint32 headCount;             // encrypted animal count
        euint64 purchasePricePerHeadUSD; // encrypted price per head
        euint64 totalPurchaseUSD;      // encrypted total purchase cost
        euint16 qualityGradeScore;     // encrypted quality grade (USDA/equiv)
        uint256 purchasedAt;
    }

    struct ProcessingBatch {
        uint256 purchaseId;
        MeatType meatType;
        euint32 inputWeightKg;         // encrypted input weight
        euint32 outputWeightKg;        // encrypted saleable output weight
        euint16 yieldEfficiencyBps;    // encrypted yield %
        euint16 coldChainScoreBps;     // encrypted cold chain compliance
        euint8  contaminationRiskScore;// encrypted contamination risk
        euint64 saleValueUSD;          // encrypted estimated sale value
        BatchStatus status;
        uint256 processedAt;
    }

    mapping(uint256 => LivestockPurchase) private purchases;
    mapping(uint256 => ProcessingBatch) private batches;
    mapping(address => bool) public isFoodSafetyInspector;
    mapping(address => bool) public isAccreditedMeatPacker;

    uint256 public purchaseCount;
    uint256 public batchCount;
    euint64 private _totalLivestockCostUSD;
    euint64 private _totalSaleValueUSD;
    euint32 private _totalRecalledKg;

    event LivestockPurchased(uint256 indexed id, MeatType meatType);
    event BatchProcessed(uint256 indexed batchId, uint256 purchaseId);
    event BatchRecalled(uint256 indexed batchId, uint256 recalledAt);

    modifier onlyFoodSafety() {
        require(isFoodSafetyInspector[msg.sender] || msg.sender == owner(), "Not food safety inspector");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalLivestockCostUSD = FHE.asEuint64(0);
        _totalSaleValueUSD = FHE.asEuint64(0);
        _totalRecalledKg = FHE.asEuint32(0);
        FHE.allowThis(_totalLivestockCostUSD);
        FHE.allowThis(_totalSaleValueUSD);
        FHE.allowThis(_totalRecalledKg);
        isFoodSafetyInspector[msg.sender] = true;
        isAccreditedMeatPacker[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addFoodSafetyInspector(address i) external onlyOwner { isFoodSafetyInspector[i] = true; }
    function accreditMeatPacker(address mp) external onlyOwner { isAccreditedMeatPacker[mp] = true; }

    function recordLivestockPurchase(
        address farmer,
        MeatType meatType,
        externalEuint32 encHeadCount, bytes calldata hcProof,
        externalEuint64 encPricePerHead, bytes calldata ppProof,
        externalEuint16 encQualityGrade, bytes calldata qgProof
    ) external whenNotPaused returns (uint256 id) {
        require(isAccreditedMeatPacker[msg.sender], "Not accredited packer");
        euint32 headCount = FHE.fromExternal(encHeadCount, hcProof);
        euint64 pricePerHead = FHE.fromExternal(encPricePerHead, ppProof);
        euint16 qualityGrade = FHE.fromExternal(encQualityGrade, qgProof);
        euint64 totalPurchase = FHE.mul(FHE.asEuint64(1), pricePerHead); // [arithmetic_overflow_underflow]
        euint64 pricePerHeadScaled = FHE.mul(pricePerHead, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        id = purchaseCount++;
        purchases[id] = LivestockPurchase({
            farmer: farmer, meatPacker: msg.sender, meatType: meatType, headCount: headCount,
            purchasePricePerHeadUSD: pricePerHead, totalPurchaseUSD: totalPurchase,
            qualityGradeScore: qualityGrade, purchasedAt: block.timestamp
        });
        _totalLivestockCostUSD = FHE.add(_totalLivestockCostUSD, totalPurchase);
        FHE.allowThis(purchases[id].headCount); FHE.allow(purchases[id].headCount, farmer); FHE.allow(purchases[id].headCount, msg.sender);
        FHE.allowThis(purchases[id].purchasePricePerHeadUSD); FHE.allow(purchases[id].purchasePricePerHeadUSD, farmer); FHE.allow(purchases[id].purchasePricePerHeadUSD, msg.sender);
        FHE.allowThis(purchases[id].totalPurchaseUSD); FHE.allow(purchases[id].totalPurchaseUSD, farmer);
        FHE.allowThis(purchases[id].qualityGradeScore);
        FHE.allowThis(_totalLivestockCostUSD);
        emit LivestockPurchased(id, meatType);
    }

    function createProcessingBatch(
        uint256 purchaseId,
        externalEuint32 encInputKg, bytes calldata ikProof,
        externalEuint32 encOutputKg, bytes calldata okProof,
        externalEuint16 encYield, bytes calldata yProof,
        externalEuint8 encContamRisk, bytes calldata crProof,
        externalEuint64 encSaleValue, bytes calldata svProof
    ) external whenNotPaused returns (uint256 batchId) {
        require(isAccreditedMeatPacker[msg.sender], "Not accredited packer");
        LivestockPurchase storage p = purchases[purchaseId];
        euint32 inputKg = FHE.fromExternal(encInputKg, ikProof);
        euint32 outputKg = FHE.fromExternal(encOutputKg, okProof);
        euint16 yieldEff = FHE.fromExternal(encYield, yProof);
        euint8 contamRisk = FHE.fromExternal(encContamRisk, crProof);
        euint64 saleValue = FHE.fromExternal(encSaleValue, svProof);
        batchId = batchCount++;
        batches[batchId].purchaseId = purchaseId;
        batches[batchId].meatType = p.meatType;
        batches[batchId].inputWeightKg = inputKg;
        batches[batchId].outputWeightKg = outputKg;
        batches[batchId].yieldEfficiencyBps = yieldEff;
        batches[batchId].coldChainScoreBps = FHE.asEuint16(10000);
        batches[batchId].contaminationRiskScore = contamRisk;
        batches[batchId].saleValueUSD = saleValue;
        batches[batchId].status = BatchStatus.Processing;
        batches[batchId].processedAt = block.timestamp;
        _totalSaleValueUSD = FHE.add(_totalSaleValueUSD, saleValue);
        FHE.allowThis(batches[batchId].inputWeightKg); FHE.allow(batches[batchId].inputWeightKg, p.meatPacker);
        FHE.allowThis(batches[batchId].outputWeightKg); FHE.allow(batches[batchId].outputWeightKg, p.meatPacker);
        FHE.allowThis(batches[batchId].yieldEfficiencyBps); FHE.allow(batches[batchId].yieldEfficiencyBps, p.meatPacker);
        FHE.allowThis(batches[batchId].coldChainScoreBps);
        FHE.allowThis(batches[batchId].contaminationRiskScore);
        FHE.allowThis(batches[batchId].saleValueUSD); FHE.allow(batches[batchId].saleValueUSD, p.meatPacker);
        FHE.allowThis(_totalSaleValueUSD);
        emit BatchProcessed(batchId, purchaseId);
    }

    function recallBatch(uint256 batchId) external onlyFoodSafety {
        ProcessingBatch storage b = batches[batchId];
        b.status = BatchStatus.Recalled;
        _totalRecalledKg = FHE.add(_totalRecalledKg, b.outputWeightKg);
        FHE.allowThis(_totalRecalledKg);
        emit BatchRecalled(batchId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalLivestockCostUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalLivestockCostUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalSaleValueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalSaleValueUSD, viewer);
        FHE.allow(_totalRecalledKg, viewer);
    }
}
