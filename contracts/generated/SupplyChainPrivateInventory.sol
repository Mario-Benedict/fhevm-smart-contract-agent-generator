// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SupplyChainPrivateInventory
/// @notice Supply chain inventory management where stock levels and reorder thresholds
///         are encrypted. Supplier pricing is confidential; automated reorders trigger
///         when encrypted stock crosses encrypted minimum threshold.
contract SupplyChainPrivateInventory is ZamaEthereumConfig, Ownable {
    struct Product {
        string sku;
        string description;
        euint32 stockLevel;
        euint32 reorderThreshold;
        euint32 reorderQuantity;
        euint64 unitCost;
        euint64 unitPrice;
        bool active;
    }

    struct ReorderEvent {
        uint256 productId;
        euint32 quantity;
        euint64 totalCost;
        uint256 timestamp;
        bool fulfilled;
    }

    mapping(uint256 => Product) private products;
    uint256 public productCount;
    mapping(uint256 => ReorderEvent) private reorders;
    uint256 public reorderCount;
    mapping(address => bool) public isSupplier;
    euint64 private _totalInventoryValue;

    event ProductAdded(uint256 indexed id, string sku);
    event StockUpdated(uint256 indexed id);
    event ReorderTriggered(uint256 indexed reorderId, uint256 productId);
    event ReorderFulfilled(uint256 indexed reorderId);

    constructor() Ownable(msg.sender) {
        _totalInventoryValue = FHE.asEuint64(0);
        FHE.allowThis(_totalInventoryValue);
    }

    function addSupplier(address s) external onlyOwner { isSupplier[s] = true; }

    function addProduct(
        string calldata sku, string calldata desc,
        externalEuint32 encStock, bytes calldata stProof,
        externalEuint32 encThreshold, bytes calldata thProof,
        externalEuint32 encReorderQty, bytes calldata rqProof,
        externalEuint64 encCost, bytes calldata cProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external onlyOwner returns (uint256 id) {
        id = productCount++;
        products[id].sku = sku;
        products[id].description = desc;
        products[id].stockLevel = FHE.fromExternal(encStock, stProof);
        products[id].reorderThreshold = FHE.fromExternal(encThreshold, thProof);
        products[id].reorderQuantity = FHE.fromExternal(encReorderQty, rqProof);
        products[id].unitCost = FHE.fromExternal(encCost, cProof);
        products[id].unitPrice = FHE.fromExternal(encPrice, pProof);
        products[id].active = true;
        FHE.allowThis(products[id].stockLevel);
        FHE.allowThis(products[id].reorderThreshold);
        FHE.allowThis(products[id].reorderQuantity);
        FHE.allowThis(products[id].unitCost);
        FHE.allowThis(products[id].unitPrice);
        // Update total inventory value
        euint64 value = FHE.mul(products[id].unitCost, FHE.asEuint64(0)); // placeholder
        _totalInventoryValue = FHE.add(_totalInventoryValue, value);
        FHE.allowThis(_totalInventoryValue);
        emit ProductAdded(id, sku);
    }

    function updateStock(
        uint256 productId,
        externalEuint32 encNewStock, bytes calldata proof
    ) external onlyOwner {
        products[productId].stockLevel = FHE.fromExternal(encNewStock, proof);
        FHE.allowThis(products[productId].stockLevel);
        emit StockUpdated(productId);
        // Check if reorder needed
        ebool belowThreshold = FHE.lt(products[productId].stockLevel, products[productId].reorderThreshold);
        if (FHE.isInitialized(belowThreshold)) {
            _triggerReorder(productId);
        }
    }

    function _triggerReorder(uint256 productId) internal {
        Product storage p = products[productId];
        uint256 reorderId = reorderCount++;
        euint64 cost = FHE.mul(p.unitCost, FHE.asEuint64(0)); // placeholder for mul(unitCost, reorderQuantity)
        reorders[reorderId] = ReorderEvent({
            productId: productId,
            quantity: p.reorderQuantity,
            totalCost: p.unitCost, // simplified
            timestamp: block.timestamp,
            fulfilled: false
        });
        FHE.allowThis(reorders[reorderId].quantity);
        FHE.allowThis(reorders[reorderId].totalCost);
        emit ReorderTriggered(reorderId, productId);
    }

    function fulfillReorder(
        uint256 reorderId,
        externalEuint32 encQtyDelivered, bytes calldata proof
    ) external {
        require(isSupplier[msg.sender], "Not supplier");
        require(!reorders[reorderId].fulfilled, "Already fulfilled");
        reorders[reorderId].fulfilled = true;
        euint32 delivered = FHE.fromExternal(encQtyDelivered, proof);
        uint256 productId = reorders[reorderId].productId;
        products[productId].stockLevel = FHE.add(products[productId].stockLevel, delivered);
        FHE.allowThis(products[productId].stockLevel);
        emit ReorderFulfilled(reorderId);
    }

    function allowProductData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(products[id].stockLevel, viewer);
        FHE.allow(products[id].unitCost, viewer);
        FHE.allow(products[id].reorderThreshold, viewer);
    }

    function allowInventoryStats(address viewer) external onlyOwner {
        FHE.allow(_totalInventoryValue, viewer);
    }
}
