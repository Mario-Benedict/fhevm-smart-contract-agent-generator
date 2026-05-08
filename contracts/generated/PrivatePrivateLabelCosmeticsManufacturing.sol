// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivatePrivateLabelCosmeticsManufacturing
/// @notice Encrypted private label cosmetics manufacturing: hidden formulation costs,
///         confidential MOQ pricing tiers, private brand-owner margin protections,
///         and encrypted regulatory compliance certification costs by market.
contract PrivatePrivateLabelCosmeticsManufacturing is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CosmeticsCategory { Skincare, Haircare, Makeup, Fragrance, PersonalCare, SunCare }
    enum RegulatoryMarket { EU, USA_FDA, Canada, Japan, Australia, China, GCC }

    struct ManufacturingOrder {
        address brand;
        address manufacturer;
        CosmeticsCategory category;
        string formulaRef;
        string productName;
        euint32 unitsOrdered;          // encrypted units
        euint64 formulationCostPerUnitUSD; // encrypted cost per unit
        euint64 totalManufacturingCostUSD; // encrypted total cost
        euint64 brandOwnerMSRPUSD;     // encrypted MSRP per unit
        euint16 brandMarginBps;        // encrypted brand margin
        euint64 regulatoryCertCostUSD; // encrypted certification cost
        bool certificationApproved;
        uint256 deliveryDate;
    }

    mapping(uint256 => ManufacturingOrder) private orders;
    mapping(address => bool) public isRegulatoryAuthority;
    mapping(address => bool) public isManufacturer;

    uint256 public orderCount;
    euint64 private _totalProductionValueUSD;
    euint64 private _totalCertCostUSD;

    event OrderPlaced(uint256 indexed id, CosmeticsCategory category, string productName);
    event OrderCertified(uint256 indexed id, uint256 certifiedAt);

    modifier onlyRegulatoryAuthority() {
        require(isRegulatoryAuthority[msg.sender] || msg.sender == owner(), "Not regulatory authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalProductionValueUSD = FHE.asEuint64(0);
        _totalCertCostUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalProductionValueUSD);
        FHE.allowThis(_totalCertCostUSD);
        isRegulatoryAuthority[msg.sender] = true;
        isManufacturer[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addRegulator(address r) external onlyOwner { isRegulatoryAuthority[r] = true; }
    function addManufacturer(address m) external onlyOwner { isManufacturer[m] = true; }

    function placeOrder(
        address manufacturer, CosmeticsCategory category, string calldata formulaRef,
        string calldata productName,
        externalEuint32 encUnits, bytes calldata uProof,
        externalEuint64 encCostPerUnit, bytes calldata cpProof,
        externalEuint64 encMSRP, bytes calldata msrpProof,
        externalEuint16 encMargin, bytes calldata mProof,
        externalEuint64 encCertCost, bytes calldata certProof,
        uint256 deliveryDays
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        require(isManufacturer[manufacturer], "Not registered manufacturer");
        euint32 units = FHE.fromExternal(encUnits, uProof);
        euint64 costPerUnit = FHE.fromExternal(encCostPerUnit, cpProof);
        euint64 msrp = FHE.fromExternal(encMSRP, msrpProof);
        euint16 margin = FHE.fromExternal(encMargin, mProof);
        euint64 certCost = FHE.fromExternal(encCertCost, certProof);
        euint64 totalCost = FHE.mul(FHE.asEuint64(1), costPerUnit);
        id = orderCount++;
        orders[id] = ManufacturingOrder({
            brand: msg.sender, manufacturer: manufacturer, category: category,
            formulaRef: formulaRef, productName: productName, unitsOrdered: units,
            formulationCostPerUnitUSD: costPerUnit, totalManufacturingCostUSD: totalCost,
            brandOwnerMSRPUSD: msrp, brandMarginBps: margin, regulatoryCertCostUSD: certCost,
            certificationApproved: false, deliveryDate: block.timestamp + deliveryDays * 1 days
        });
        _totalProductionValueUSD = FHE.add(_totalProductionValueUSD, totalCost);
        _totalCertCostUSD = FHE.add(_totalCertCostUSD, certCost);
        FHE.allowThis(orders[id].unitsOrdered); FHE.allow(orders[id].unitsOrdered, msg.sender);
        FHE.allowThis(orders[id].formulationCostPerUnitUSD); FHE.allow(orders[id].formulationCostPerUnitUSD, manufacturer);
        FHE.allowThis(orders[id].totalManufacturingCostUSD); FHE.allow(orders[id].totalManufacturingCostUSD, msg.sender); FHE.allow(orders[id].totalManufacturingCostUSD, manufacturer);
        FHE.allowThis(orders[id].brandOwnerMSRPUSD); FHE.allow(orders[id].brandOwnerMSRPUSD, msg.sender);
        FHE.allowThis(orders[id].brandMarginBps); FHE.allow(orders[id].brandMarginBps, msg.sender);
        FHE.allowThis(orders[id].regulatoryCertCostUSD); FHE.allow(orders[id].regulatoryCertCostUSD, msg.sender);
        FHE.allowThis(_totalProductionValueUSD);
        FHE.allowThis(_totalCertCostUSD);
        emit OrderPlaced(id, category, productName);
    }

    function certifyOrder(uint256 orderId) external onlyRegulatoryAuthority {
        orders[orderId].certificationApproved = true;
        emit OrderCertified(orderId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalProductionValueUSD, viewer);
        FHE.allow(_totalCertCostUSD, viewer);
    }
}
