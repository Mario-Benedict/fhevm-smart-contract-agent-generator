// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedDrugCounterfeitDetection
/// @notice Pharmaceutical anti-counterfeiting: encrypted batch authenticity scores,
///         encrypted serialization codes, and supply chain integrity checks.
contract EncryptedDrugCounterfeitDetection is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum AuthStatus { Authentic, Suspect, Confirmed_Counterfeit, Under_Investigation }
    enum ChainNode { Manufacturer, Wholesaler, Distributor, Pharmacy, Hospital }

    struct DrugBatch {
        string ndcCode;                 // National Drug Code
        string brandName;
        address manufacturer;
        euint64 batchSizeUnits;         // encrypted batch size
        euint32 authenticityScore;     // encrypted authenticity score (0-1000)
        euint16 tamperIndicatorBps;    // encrypted tamper evidence reading
        euint64 expiryTimestamp;       // encrypted expiry (as timestamp)
        AuthStatus status;
        bool recalled;
    }

    struct SerialUnit {
        uint256 batchId;
        euint32 serialHash;            // encrypted serial number hash
        ChainNode currentNode;
        address currentCustodian;
        euint32 scanScore;             // encrypted scan integrity score
        uint256 lastScanTime;
        bool flagged;
    }

    mapping(uint256 => DrugBatch) private batches;
    mapping(uint256 => SerialUnit) private units;
    mapping(uint256 => uint256[]) private batchUnits;
    mapping(address => bool) public isRegulator;
    mapping(address => ChainNode) public nodeType;

    uint256 public batchCount;
    uint256 public unitCount;
    euint64 private _totalBatchesProcessed;
    euint32 private _avgAuthenticityScore;

    event BatchRegistered(uint256 indexed id, string ndcCode, address manufacturer);
    event UnitScanned(uint256 indexed unitId, ChainNode node, address custodian);
    event UnitFlagged(uint256 indexed unitId, string reason);
    event BatchRecalled(uint256 indexed batchId, string reason);

    modifier onlyRegulator() {
        require(isRegulator[msg.sender] || msg.sender == owner(), "Not regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalBatchesProcessed = FHE.asEuint64(0);
        _avgAuthenticityScore = FHE.asEuint32(0);
        FHE.allowThis(_totalBatchesProcessed);
        FHE.allowThis(_avgAuthenticityScore);
        isRegulator[msg.sender] = true;
    }

    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }
    function registerNode(address node, ChainNode nType) external onlyOwner { nodeType[node] = nType; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerBatch(
        string calldata ndcCode,
        string calldata brandName,
        externalEuint64 encBatchSize, bytes calldata bsProof,
        externalEuint32 encAuthScore, bytes calldata asProof,
        externalEuint16 encTamper, bytes calldata tProof,
        uint256 expiryDays
    ) external whenNotPaused returns (uint256 id) {
        euint64 batchSize = FHE.fromExternal(encBatchSize, bsProof);
        euint32 authScore = FHE.fromExternal(encAuthScore, asProof);
        euint16 tamper = FHE.fromExternal(encTamper, tProof);
        id = batchCount++;
        batches[id].ndcCode = ndcCode;
        batches[id].brandName = brandName;
        batches[id].manufacturer = msg.sender;
        batches[id].batchSizeUnits = batchSize;
        batches[id].authenticityScore = authScore;
        batches[id].tamperIndicatorBps = tamper;
        batches[id].expiryTimestamp = FHE.asEuint64(uint64(block.timestamp + expiryDays * 1 days));
        batches[id].status = AuthStatus.Authentic;
        batches[id].recalled = false;
        _totalBatchesProcessed = FHE.add(_totalBatchesProcessed, FHE.asEuint64(1));
        FHE.allowThis(batches[id].batchSizeUnits);
        FHE.allow(batches[id].batchSizeUnits, msg.sender);
        FHE.allowThis(batches[id].authenticityScore);
        FHE.allow(batches[id].authenticityScore, msg.sender);
        FHE.allowThis(batches[id].tamperIndicatorBps);
        FHE.allowThis(batches[id].expiryTimestamp);
        FHE.allow(batches[id].expiryTimestamp, msg.sender);
        FHE.allowThis(_totalBatchesProcessed);
        emit BatchRegistered(id, ndcCode, msg.sender);
    }

    function mintUnit(
        uint256 batchId,
        externalEuint32 encSerial, bytes calldata proof
    ) external whenNotPaused returns (uint256 unitId) {
        require(batches[batchId].manufacturer == msg.sender, "Not manufacturer");
        euint32 serial = FHE.fromExternal(encSerial, proof);
        unitId = unitCount++;
        units[unitId] = SerialUnit({
            batchId: batchId, serialHash: serial,
            currentNode: ChainNode.Manufacturer, currentCustodian: msg.sender,
            scanScore: FHE.asEuint32(1000), lastScanTime: block.timestamp, flagged: false
        });
        batchUnits[batchId].push(unitId);
        FHE.allowThis(units[unitId].serialHash);
        FHE.allow(units[unitId].serialHash, msg.sender);
        FHE.allowThis(units[unitId].scanScore);
    }

    function scanUnit(
        uint256 unitId,
        externalEuint32 encScanScore, bytes calldata proof,
        ChainNode node
    ) external whenNotPaused {
        SerialUnit storage u = units[unitId];
        require(!u.flagged, "Unit is flagged");
        euint32 scanScore = FHE.fromExternal(encScanScore, proof);
        // Flag if score drops below 500
        ebool suspicious = FHE.lt(scanScore, FHE.asEuint32(500));
        u.scanScore = scanScore;
        u.currentNode = node;
        u.currentCustodian = msg.sender;
        u.lastScanTime = block.timestamp;
        u.flagged = FHE.isInitialized(suspicious);
        FHE.allowThis(u.scanScore);
        FHE.allow(u.scanScore, msg.sender);
        if (u.flagged) {
            batches[u.batchId].status = AuthStatus.Suspect;
            emit UnitFlagged(unitId, "Low scan score");
        }
        emit UnitScanned(unitId, node, msg.sender);
    }

    function investigateBatch(uint256 batchId) external onlyRegulator {
        batches[batchId].status = AuthStatus.Under_Investigation;
    }

    function recallBatch(uint256 batchId, string calldata reason) external onlyRegulator {
        batches[batchId].recalled = true;
        batches[batchId].status = AuthStatus.Confirmed_Counterfeit;
        emit BatchRecalled(batchId, reason);
    }

    function allowBatchDetails(uint256 batchId, address viewer) external onlyRegulator {
        DrugBatch storage b = batches[batchId];
        FHE.allow(b.batchSizeUnits, viewer);
        FHE.allow(b.authenticityScore, viewer);
        FHE.allow(b.tamperIndicatorBps, viewer);
        FHE.allow(b.expiryTimestamp, viewer);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalBatchesProcessed, viewer);
        FHE.allow(_avgAuthenticityScore, viewer);
    }
}
