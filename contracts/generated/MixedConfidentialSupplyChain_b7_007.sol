// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title MixedConfidentialSupplyChain_b7_007 - Supply chain with encrypted inventory
contract MixedConfidentialSupplyChain_b7_007 is ZamaEthereumConfig {
    address public coordinator;

    struct Product {
        string sku;
        euint32 quantity;
        euint64 unitCost;
        address currentHolder;
        bool exists;
    }

    mapping(bytes32 => Product) private products;
    mapping(address => bool) public isParticipant;

    modifier onlyCoordinator() {
        require(msg.sender == coordinator, "Not coordinator");
        _;
    }

    modifier onlyParticipant() {
        require(isParticipant[msg.sender] || msg.sender == coordinator, "Not participant");
        _;
    }

    constructor() {
        coordinator = msg.sender;
        isParticipant[msg.sender] = true;
    }

    function addParticipant(address p) public onlyCoordinator {
        isParticipant[p] = true;
    }

    function createProduct(
        string calldata sku,
        externalEuint32 quantityStr, bytes calldata qProof,
        externalEuint64 costStr, bytes calldata cProof
    ) public onlyCoordinator returns (bytes32) {
        bytes32 id = keccak256(abi.encodePacked(sku, block.timestamp));
        euint32 qty = FHE.fromExternal(quantityStr, qProof);
        euint64 cost = FHE.fromExternal(costStr, cProof);
        products[id] = Product({ sku: sku, quantity: qty, unitCost: cost, currentHolder: msg.sender, exists: true });
        FHE.allowThis(products[id].quantity);
        FHE.allowThis(products[id].unitCost);
        return id;
    }

    function transfer(bytes32 productId, address newHolder, externalEuint32 qtyStr, bytes calldata proof) public onlyParticipant {
        require(products[productId].exists, "Product not found");
        require(products[productId].currentHolder == msg.sender, "Not holder");
        euint32 qty = FHE.fromExternal(qtyStr, proof);
        ebool ok = FHE.le(qty, products[productId].quantity);
        euint32 actual = FHE.select(ok, qty, FHE.asEuint32(0));
        products[productId].quantity = FHE.sub(products[productId].quantity, actual);
        products[productId].currentHolder = newHolder;
        FHE.allowThis(products[productId].quantity);
        FHE.allow(products[productId].quantity, newHolder);
        FHE.allow(products[productId].unitCost, newHolder);
    }

    function allowProductInfo(bytes32 productId, address viewer) public onlyCoordinator {
        FHE.allow(products[productId].quantity, viewer);
        FHE.allow(products[productId].unitCost, viewer);
    }
}
