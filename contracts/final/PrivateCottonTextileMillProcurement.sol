// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCottonTextileMillProcurement
/// @notice Encrypted cotton textile mill procurement: hidden cotton bale prices, confidential
///         staple length and quality specs, private dyeing chemical cost tracking,
///         and encrypted finished fabric pricing to retailers.
contract PrivateCottonTextileMillProcurement is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FiberOrigin { US_Upland, EgyptianGiza, PimaUS, Australian, Indian, Brazilian }
    enum FabricType { Denim, Poplin, Muslin, Canvas, Twill, Jersey }

    struct CottonProcurementOrder {
        address gin;
        address mill;
        FiberOrigin origin;
        euint32 balesOrdered;          // encrypted bale count
        euint64 pricePerBaleUSD;       // encrypted price per bale
        euint64 totalOrderValueUSD;    // encrypted total order value
        euint16 stapleLength32nds;     // encrypted staple length
        euint16 micronaireBps;         // encrypted micronaire (fineness)
        euint16 strengthGramsTex;      // encrypted fiber strength
        uint256 deliveryDate;
        bool delivered;
    }

    struct FabricProductionRun {
        uint256 procurementId;
        FabricType fabricType;
        euint32 metersProduced;        // encrypted meters of fabric
        euint64 dyeChemicalCostUSD;    // encrypted dyeing/finishing cost
        euint64 productionCostTotalUSD;// encrypted total production cost
        euint64 wholesaleRevenueUSD;   // encrypted fabric sale price
        uint256 producedAt;
    }

    mapping(uint256 => CottonProcurementOrder) private orders;
    mapping(uint256 => FabricProductionRun) private productionRuns;
    mapping(address => bool) public isMillAdmin;

    uint256 public orderCount;
    uint256 public productionCount;
    euint64 private _totalFiberCostUSD;
    euint64 private _totalFabricRevenueUSD;

    event OrderPlaced(uint256 indexed id, FiberOrigin origin);
    event ProductionRunCompleted(uint256 indexed id, FabricType fabricType);

    modifier onlyMillAdmin() {
        require(isMillAdmin[msg.sender] || msg.sender == owner(), "Not mill admin");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalFiberCostUSD = FHE.asEuint64(0);
        _totalFabricRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalFiberCostUSD);
        FHE.allowThis(_totalFabricRevenueUSD);
        isMillAdmin[msg.sender] = true;
    }

    function addMillAdmin(address a) external onlyOwner { isMillAdmin[a] = true; }

    function placeProcurementOrder(
        address gin, FiberOrigin origin,
        externalEuint32 encBales, bytes calldata bProof,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint16 encStaple, bytes calldata stProof,
        externalEuint16 encMicronaire, bytes calldata micProof,
        externalEuint16 encStrength, bytes calldata strProof,
        uint256 deliveryDays
    ) external onlyMillAdmin returns (uint256 id) {
        euint32 bales = FHE.fromExternal(encBales, bProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint16 staple = FHE.fromExternal(encStaple, stProof);
        euint16 micronaire = FHE.fromExternal(encMicronaire, micProof);
        euint16 strength = FHE.fromExternal(encStrength, strProof);
        euint64 totalValue = FHE.mul(FHE.asEuint64(1), price);
        id = orderCount++;
        orders[id].gin = gin;
        orders[id].mill = msg.sender;
        orders[id].origin = origin;
        orders[id].balesOrdered = bales;
        orders[id].pricePerBaleUSD = price;
        orders[id].totalOrderValueUSD = totalValue;
        orders[id].stapleLength32nds = staple;
        orders[id].micronaireBps = micronaire;
        orders[id].strengthGramsTex = strength;
        orders[id].deliveryDate = block.timestamp + deliveryDays * 1 days;
        orders[id].delivered = false;
        _totalFiberCostUSD = FHE.add(_totalFiberCostUSD, totalValue);
        FHE.allowThis(orders[id].balesOrdered); FHE.allow(orders[id].balesOrdered, msg.sender); FHE.allow(orders[id].balesOrdered, gin);
        FHE.allowThis(orders[id].pricePerBaleUSD); FHE.allow(orders[id].pricePerBaleUSD, msg.sender); FHE.allow(orders[id].pricePerBaleUSD, gin);
        FHE.allowThis(orders[id].totalOrderValueUSD); FHE.allow(orders[id].totalOrderValueUSD, msg.sender);
        FHE.allowThis(orders[id].stapleLength32nds);
        FHE.allowThis(orders[id].micronaireBps);
        FHE.allowThis(orders[id].strengthGramsTex);
        FHE.allowThis(_totalFiberCostUSD);
        emit OrderPlaced(id, origin);
    }

    function recordProductionRun(
        uint256 procurementId, FabricType fabricType,
        externalEuint32 encMeters, bytes calldata mProof,
        externalEuint64 encDyeCost, bytes calldata dcProof,
        externalEuint64 encTotalCost, bytes calldata tcProof,
        externalEuint64 encRevenue, bytes calldata rProof
    ) external onlyMillAdmin returns (uint256 runId) {
        euint32 meters = FHE.fromExternal(encMeters, mProof);
        euint64 dyeCost = FHE.fromExternal(encDyeCost, dcProof);
        euint64 totalCost = FHE.fromExternal(encTotalCost, tcProof);
        euint64 revenue = FHE.fromExternal(encRevenue, rProof);
        runId = productionCount++;
        productionRuns[runId] = FabricProductionRun({
            procurementId: procurementId, fabricType: fabricType, metersProduced: meters,
            dyeChemicalCostUSD: dyeCost, productionCostTotalUSD: totalCost,
            wholesaleRevenueUSD: revenue, producedAt: block.timestamp
        });
        _totalFabricRevenueUSD = FHE.add(_totalFabricRevenueUSD, revenue);
        FHE.allowThis(productionRuns[runId].metersProduced); FHE.allow(productionRuns[runId].metersProduced, msg.sender);
        FHE.allowThis(productionRuns[runId].dyeChemicalCostUSD); FHE.allow(productionRuns[runId].dyeChemicalCostUSD, msg.sender);
        FHE.allowThis(productionRuns[runId].productionCostTotalUSD); FHE.allow(productionRuns[runId].productionCostTotalUSD, msg.sender);
        FHE.allowThis(productionRuns[runId].wholesaleRevenueUSD); FHE.allow(productionRuns[runId].wholesaleRevenueUSD, msg.sender);
        FHE.allowThis(_totalFabricRevenueUSD);
        emit ProductionRunCompleted(runId, fabricType);
    }

    function allowMillStats(address viewer) external onlyOwner {
        FHE.allow(_totalFiberCostUSD, viewer);
        FHE.allow(_totalFabricRevenueUSD, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}