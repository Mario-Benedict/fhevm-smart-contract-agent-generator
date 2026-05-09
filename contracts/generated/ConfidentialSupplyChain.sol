// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ConfidentialSupplyChain - Encrypted supply chain tracking with private cost and margin data
contract ConfidentialSupplyChain is ZamaEthereumConfig, AccessControl {
    bytes32 public constant SUPPLIER_ROLE = keccak256("SUPPLIER_ROLE");
    bytes32 public constant MANUFACTURER_ROLE = keccak256("MANUFACTURER_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    enum Stage { Raw, Processed, Packaged, Shipped, Delivered }

    struct Shipment {
        bytes32 productId;
        Stage currentStage;
        address currentHolder;
        euint64 currentCost;
        euint64 unitPrice;
        euint32 quantity;
        euint8 qualityScore;
        uint256 lastUpdated;
        bool active;
    }

    mapping(uint256 => Shipment) public shipments;
    mapping(uint256 => address[]) public shipmentHandlers;
    uint256 public shipmentCount;

    event ShipmentCreated(uint256 indexed shipmentId, bytes32 productId);
    event StageAdvanced(uint256 indexed shipmentId, Stage newStage, address indexed handler);
    event QualityRecorded(uint256 indexed shipmentId, address indexed inspector);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function createShipment(
        bytes32 productId,
        externalEuint64 encCost,
        bytes calldata costProof,
        externalEuint32 encQty,
        bytes calldata qtyProof
    ) external onlyRole(SUPPLIER_ROLE) returns (uint256 shipmentId) {
        shipmentId = shipmentCount++;
        Shipment storage s = shipments[shipmentId];
        s.productId = productId;
        s.currentStage = Stage.Raw;
        s.currentHolder = msg.sender;
        s.currentCost = FHE.fromExternal(encCost, costProof);
        s.quantity = FHE.fromExternal(encQty, qtyProof);
        s.unitPrice = FHE.asEuint64(0);
        s.qualityScore = FHE.asEuint8(0);
        s.lastUpdated = block.timestamp;
        s.active = true;
        FHE.allowThis(s.currentCost);
        FHE.allowThis(s.quantity);
        FHE.allowThis(s.unitPrice);
        FHE.allowThis(s.qualityScore);
        FHE.allow(s.currentCost, msg.sender);
        shipmentHandlers[shipmentId].push(msg.sender);
        emit ShipmentCreated(shipmentId, productId);
    }

    function advanceStage(
        uint256 shipmentId,
        externalEuint64 encAddedCost,
        bytes calldata costProof
    ) external {
        Shipment storage s = shipments[shipmentId];
        require(s.active, "Inactive");
        require(uint8(s.currentStage) < uint8(Stage.Delivered), "Already delivered");
        euint64 addedCost = FHE.fromExternal(encAddedCost, costProof);
        s.currentCost = FHE.add(s.currentCost, addedCost);
        s.currentStage = Stage(uint8(s.currentStage) + 1);
        s.currentHolder = msg.sender;
        s.lastUpdated = block.timestamp;
        FHE.allowThis(s.currentCost);
        FHE.allow(s.currentCost, msg.sender);
        shipmentHandlers[shipmentId].push(msg.sender);
        emit StageAdvanced(shipmentId, s.currentStage, msg.sender);
    }

    function recordQuality(uint256 shipmentId, externalEuint8 encScore, bytes calldata inputProof)
        external
        onlyRole(AUDITOR_ROLE)
    {
        euint8 score = FHE.fromExternal(encScore, inputProof);
        shipments[shipmentId].qualityScore = score;
        FHE.allowThis(shipments[shipmentId].qualityScore);
        FHE.allow(shipments[shipmentId].qualityScore, shipments[shipmentId].currentHolder);
        FHE.allow(shipments[shipmentId].qualityScore, msg.sender);
        emit QualityRecorded(shipmentId, msg.sender);
    }

    function setUnitPrice(uint256 shipmentId, externalEuint64 encPrice, bytes calldata inputProof)
        external
    {
        require(shipments[shipmentId].currentHolder == msg.sender, "Not holder");
        euint64 price = FHE.fromExternal(encPrice, inputProof);
        shipments[shipmentId].unitPrice = price;
        FHE.allowThis(shipments[shipmentId].unitPrice);
        FHE.allow(shipments[shipmentId].unitPrice, msg.sender);
    }

    function getHandlerCount(uint256 shipmentId) external view returns (uint256) {
        return shipmentHandlers[shipmentId].length;
    }
}
