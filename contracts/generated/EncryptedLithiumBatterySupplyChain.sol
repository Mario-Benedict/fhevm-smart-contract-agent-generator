// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedLithiumBatterySupplyChain
/// @notice Tracks battery raw materials (lithium, cobalt, nickel) with encrypted volumes,
///         supplier prices, and sustainability scores through the EV supply chain.
contract EncryptedLithiumBatterySupplyChain is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum MaterialType { Lithium, Cobalt, Nickel, Manganese, GraphiteAnode }
    enum CheckpointType { Mining, Refining, CellManufacturing, PackAssembly, OEM }

    struct SupplierRecord {
        string supplierName;
        string countryOfOrigin;
        MaterialType material;
        euint32 sustainabilityScore;   // encrypted ESG score 0-100
        euint64 pricePerKgCents;       // encrypted price
        euint64 totalVolumeKg;         // encrypted cumulative volume
        bool certified;
    }

    struct MaterialLot {
        uint256 supplierId;
        MaterialType material;
        euint64 quantityKg;            // encrypted lot quantity
        euint64 pricePaidCents;        // encrypted total cost
        euint32 qualityScore;          // encrypted quality rating
        CheckpointType currentCheckpoint;
        uint256 timestamp;
        bool flagged;
    }

    mapping(uint256 => SupplierRecord) private suppliers;
    mapping(uint256 => MaterialLot) private lots;
    mapping(address => uint256) public addressToSupplier;
    mapping(address => bool) public isAuditor;

    uint256 public supplierCount;
    uint256 public lotCount;
    euint64 private _totalProcurementCosts;
    euint32 private _avgSustainabilityScore;

    event SupplierRegistered(uint256 indexed id, string name, MaterialType material);
    event LotCreated(uint256 indexed lotId, uint256 supplierId);
    event LotAdvanced(uint256 indexed lotId, CheckpointType checkpoint);
    event LotFlagged(uint256 indexed lotId, string reason);

    modifier onlyAuditor() {
        require(isAuditor[msg.sender] || msg.sender == owner(), "Not auditor");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalProcurementCosts = FHE.asEuint64(0);
        _avgSustainabilityScore = FHE.asEuint32(0);
        FHE.allowThis(_totalProcurementCosts);
        FHE.allowThis(_avgSustainabilityScore);
        isAuditor[msg.sender] = true;
    }

    function addAuditor(address a) external onlyOwner { isAuditor[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerSupplier(
        string calldata supplierName,
        string calldata country,
        MaterialType material,
        externalEuint32 encScore, bytes calldata sProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external onlyOwner returns (uint256 id) {
        euint32 score = FHE.fromExternal(encScore, sProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        id = supplierCount++;
        suppliers[id] = SupplierRecord({
            supplierName: supplierName, countryOfOrigin: country, material: material,
            sustainabilityScore: score, pricePerKgCents: price,
            totalVolumeKg: FHE.asEuint64(0), certified: false
        });
        FHE.allowThis(suppliers[id].sustainabilityScore);
        FHE.allowThis(suppliers[id].pricePerKgCents);
        FHE.allowThis(suppliers[id].totalVolumeKg);
        emit SupplierRegistered(id, supplierName, material);
    }

    function certifySupplier(uint256 supplierId) external onlyAuditor {
        suppliers[supplierId].certified = true;
    }

    function createLot(
        uint256 supplierId,
        externalEuint64 encQty, bytes calldata qProof,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint32 encQuality, bytes calldata qlProof
    ) external whenNotPaused nonReentrant returns (uint256 lotId) {
        SupplierRecord storage s = suppliers[supplierId];
        require(s.certified, "Supplier not certified");
        euint64 qty = FHE.fromExternal(encQty, qProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint32 quality = FHE.fromExternal(encQuality, qlProof);
        lotId = lotCount++;
        lots[lotId] = MaterialLot({
            supplierId: supplierId, material: s.material,
            quantityKg: qty, pricePaidCents: price,
            qualityScore: quality,
            currentCheckpoint: CheckpointType.Mining,
            timestamp: block.timestamp, flagged: false
        });
        s.totalVolumeKg = FHE.add(s.totalVolumeKg, qty);
        _totalProcurementCosts = FHE.add(_totalProcurementCosts, price);
        FHE.allowThis(lots[lotId].quantityKg);
        FHE.allowThis(lots[lotId].pricePaidCents);
        FHE.allowThis(lots[lotId].qualityScore);
        FHE.allowThis(s.totalVolumeKg);
        FHE.allowThis(_totalProcurementCosts);
        emit LotCreated(lotId, supplierId);
    }

    function advanceLot(uint256 lotId, CheckpointType next) external onlyAuditor {
        MaterialLot storage lot = lots[lotId];
        require(!lot.flagged, "Lot is flagged");
        lot.currentCheckpoint = next;
        lot.timestamp = block.timestamp;
        emit LotAdvanced(lotId, next);
    }

    function flagLot(uint256 lotId, string calldata reason) external onlyAuditor {
        lots[lotId].flagged = true;
        emit LotFlagged(lotId, reason);
    }

    function allowLotDetails(uint256 lotId, address viewer) external onlyAuditor {
        FHE.allow(lots[lotId].quantityKg, viewer);
        FHE.allow(lots[lotId].pricePaidCents, viewer);
        FHE.allow(lots[lotId].qualityScore, viewer);
    }

    function allowChainStats(address viewer) external onlyOwner {
        FHE.allow(_totalProcurementCosts, viewer);
        FHE.allow(_avgSustainabilityScore, viewer);
    }
}
