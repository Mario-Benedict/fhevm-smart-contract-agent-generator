// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivatePharmaSupplyChainAuthenticity
/// @notice Encrypted pharmaceutical authenticity tracking: hidden batch quantities, confidential
///         serialization codes, private cold-chain temperature compliance records, and encrypted
///         recall scope assessments by regulatory authority.
contract PrivatePharmaSupplyChainAuthenticity is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum PharmaTier { Manufacturer, DistributionCenter, WholesaleDistributor, Pharmacy, Hospital }
    enum BatchStatus { InProduction, Released, InTransit, Delivered, Quarantined, Recalled }

    struct PharmaBatch {
        address manufacturer;
        string productCode;
        string batchNumber;
        euint32 unitCount;              // encrypted unit count
        euint64 batchValueUSD;          // encrypted batch value
        euint16 temperatureRecordBps;   // encrypted temp compliance score
        euint8  authenticityScore;      // encrypted authenticity confidence (0-100)
        euint32 serialRangeStart;       // encrypted serial number range start
        BatchStatus status;
        uint256 manufacturedAt;
        uint256 expiryTimestamp;
    }

    struct CustodyTransfer {
        uint256 batchId;
        address fromEntity;
        address toEntity;
        PharmaTier toTier;
        euint64 transferValueUSD;       // encrypted transfer price
        euint16 conditionScore;         // encrypted condition at handover
        uint256 transferredAt;
    }

    mapping(uint256 => PharmaBatch) private batches;
    mapping(uint256 => CustodyTransfer) private transfers;
    mapping(address => PharmaTier) public entityTier;
    mapping(address => bool) public isRegulatory;

    uint256 public batchCount;
    uint256 public transferCount;
    euint64 private _totalBatchValueUSD;
    euint32 private _totalRecalledUnits;

    event BatchCreated(uint256 indexed id, string productCode, string batchNumber);
    event CustodyTransferred(uint256 indexed transferId, uint256 batchId, address toEntity);
    event BatchRecalled(uint256 indexed batchId, uint256 recalledAt);

    modifier onlyRegulatory() {
        require(isRegulatory[msg.sender] || msg.sender == owner(), "Not regulatory authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalBatchValueUSD = FHE.asEuint64(0);
        _totalRecalledUnits = FHE.asEuint32(0);
        FHE.allowThis(_totalBatchValueUSD);
        FHE.allowThis(_totalRecalledUnits);
        isRegulatory[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addRegulatory(address r) external onlyOwner { isRegulatory[r] = true; }
    function setEntityTier(address entity, PharmaTier tier) external onlyOwner { entityTier[entity] = tier; }

    function createBatch(
        string calldata productCode,
        string calldata batchNumber,
        externalEuint32 encUnits, bytes calldata uProof,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint8 encAuthenticity, bytes calldata authProof,
        externalEuint32 encSerialStart, bytes calldata ssProof,
        uint256 expiryDays
    ) external whenNotPaused returns (uint256 id) {
        euint32 units = FHE.fromExternal(encUnits, uProof);
        euint64 batchVal = FHE.fromExternal(encValue, vProof);
        euint8 authenticity = FHE.fromExternal(encAuthenticity, authProof);
        euint32 serialStart = FHE.fromExternal(encSerialStart, ssProof);
        id = batchCount++;
        batches[id].manufacturer = msg.sender;
        batches[id].productCode = productCode;
        batches[id].batchNumber = batchNumber;
        batches[id].unitCount = units;
        batches[id].batchValueUSD = batchVal;
        batches[id].temperatureRecordBps = FHE.asEuint16(10000);
        batches[id].authenticityScore = authenticity;
        batches[id].serialRangeStart = serialStart;
        batches[id].status = BatchStatus.InProduction;
        batches[id].manufacturedAt = block.timestamp;
        batches[id].expiryTimestamp = block.timestamp + expiryDays * 1 days;
        _totalBatchValueUSD = FHE.add(_totalBatchValueUSD, batchVal);
        FHE.allowThis(batches[id].unitCount); FHE.allow(batches[id].unitCount, msg.sender);
        FHE.allowThis(batches[id].batchValueUSD); FHE.allow(batches[id].batchValueUSD, msg.sender);
        FHE.allowThis(batches[id].temperatureRecordBps);
        FHE.allowThis(batches[id].authenticityScore);
        FHE.allowThis(batches[id].serialRangeStart); FHE.allow(batches[id].serialRangeStart, msg.sender);
        FHE.allowThis(_totalBatchValueUSD);
        emit BatchCreated(id, productCode, batchNumber);
    }

    function releaseBatch(uint256 batchId) external onlyRegulatory {
        batches[batchId].status = BatchStatus.Released;
    }

    function transferCustody(
        uint256 batchId,
        address toEntity,
        externalEuint64 encTransferValue, bytes calldata tvProof,
        externalEuint16 encCondition, bytes calldata condProof
    ) external whenNotPaused nonReentrant returns (uint256 transferId) {
        PharmaBatch storage b = batches[batchId];
        require(b.status == BatchStatus.Released || b.status == BatchStatus.InTransit, "Not transferable");
        euint64 tVal = FHE.fromExternal(encTransferValue, tvProof);
        euint16 condition = FHE.fromExternal(encCondition, condProof);
        transferId = transferCount++;
        transfers[transferId] = CustodyTransfer({
            batchId: batchId, fromEntity: msg.sender, toEntity: toEntity,
            toTier: entityTier[toEntity], transferValueUSD: tVal,
            conditionScore: condition, transferredAt: block.timestamp
        });
        b.status = BatchStatus.InTransit;
        // Update temp compliance: select min of current and new condition
        ebool conditionBetter = FHE.ge(condition, b.temperatureRecordBps);
        b.temperatureRecordBps = FHE.select(conditionBetter, b.temperatureRecordBps, condition);
        FHE.allowThis(transfers[transferId].transferValueUSD); FHE.allow(transfers[transferId].transferValueUSD, msg.sender); FHE.allow(transfers[transferId].transferValueUSD, toEntity);
        FHE.allowThis(transfers[transferId].conditionScore); FHE.allow(transfers[transferId].conditionScore, toEntity);
        FHE.allowThis(b.temperatureRecordBps);
        emit CustodyTransferred(transferId, batchId, toEntity);
    }

    function recallBatch(uint256 batchId) external onlyRegulatory {
        PharmaBatch storage b = batches[batchId];
        b.status = BatchStatus.Recalled;
        _totalRecalledUnits = FHE.add(_totalRecalledUnits, b.unitCount);
        FHE.allowThis(_totalRecalledUnits);
        emit BatchRecalled(batchId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalBatchValueUSD, viewer);
        FHE.allow(_totalRecalledUnits, viewer);
    }
}
