// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSupplyChainCarbonFootprintTracker
/// @notice Encrypted supply chain carbon tracker: hidden scope 1/2/3 emissions
///         per supplier, private carbon intensity scores, confidential offset
///         purchases, and encrypted net-zero pathway compliance monitoring.
contract EncryptedSupplyChainCarbonFootprintTracker is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum EmissionScope { Scope1_Direct, Scope2_Indirect, Scope3_ValueChain }
    enum SupplierTier  { Tier1, Tier2, Tier3, RawMaterials }
    enum NetZeroStatus { NotStarted, Committed, InProgress, Achieved }

    struct SupplierEmissionProfile {
        address supplier;
        SupplierTier tier;
        string supplierRef;
        euint64 scope1tCO2e;           // encrypted scope 1
        euint64 scope2tCO2e;           // encrypted scope 2
        euint64 scope3tCO2e;           // encrypted scope 3
        euint64 offsetstCO2e;          // encrypted offsets purchased
        euint64 carbonIntensityScore;  // encrypted intensity (tCO2e/$M revenue)
        euint16 sbtiAlignmentScore;    // encrypted SBTi alignment
        NetZeroStatus netZeroStatus;
        uint256 reportingYear;
        bool verified;
    }

    struct OffsetPurchase {
        uint256 supplierId;
        string  offsetProjectRef;
        euint64 volumetCO2e;           // encrypted offset volume
        euint64 pricePerTonneUSD;      // encrypted price
        uint256 purchasedAt;
        bool retired;
    }

    mapping(uint256 => SupplierEmissionProfile) private suppliers;
    mapping(uint256 => OffsetPurchase) private offsets;
    mapping(address => bool) public isClimateAuditor;

    uint256 public supplierCount;
    uint256 public offsetCount;
    euint64 private _totalScope1tCO2e;
    euint64 private _totalScope2tCO2e;
    euint64 private _totalScope3tCO2e;
    euint64 private _totalOffsettCO2e;
    euint64 private _totalOffsetSpendUSD;

    event SupplierProfileCreated(uint256 indexed id, SupplierTier tier);
    event EmissionsUpdated(uint256 indexed supplierId, uint256 reportingYear);
    event OffsetPurchased(uint256 indexed offsetId, uint256 supplierId);

    modifier onlyClimateAuditor() {
        require(isClimateAuditor[msg.sender] || msg.sender == owner(), "Not climate auditor");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalScope1tCO2e = FHE.asEuint64(0); _totalScope2tCO2e = FHE.asEuint64(0); _totalScope3tCO2e = FHE.asEuint64(0);
        _totalOffsettCO2e = FHE.asEuint64(0); _totalOffsetSpendUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalScope1tCO2e); FHE.allowThis(_totalScope2tCO2e); FHE.allowThis(_totalScope3tCO2e);
        FHE.allowThis(_totalOffsettCO2e); FHE.allowThis(_totalOffsetSpendUSD);
        isClimateAuditor[msg.sender] = true;
    }

    function addClimateAuditor(address ca) external onlyOwner { isClimateAuditor[ca] = true; }

    function createSupplierProfile(
        address supplier, SupplierTier tier, string calldata supplierRef, uint256 reportingYear
    ) external returns (uint256 id) {
        id = supplierCount++;
        SupplierEmissionProfile storage _s0 = suppliers[id];
        _s0.supplier = supplier;
        _s0.tier = tier;
        _s0.supplierRef = supplierRef;
        _s0.scope1tCO2e = FHE.asEuint64(0);
        _s0.scope2tCO2e = FHE.asEuint64(0);
        _s0.scope3tCO2e = FHE.asEuint64(0);
        _s0.offsetstCO2e = FHE.asEuint64(0);
        _s0.carbonIntensityScore = FHE.asEuint64(0);
        _s0.sbtiAlignmentScore = FHE.asEuint16(0);
        _s0.netZeroStatus = NetZeroStatus.NotStarted;
        _s0.reportingYear = reportingYear;
        _s0.verified = false;
        FHE.allowThis(suppliers[id].scope1tCO2e); FHE.allow(suppliers[id].scope1tCO2e, supplier); // [acl_misconfig]
        FHE.allow(_totalScope1tCO2e, msg.sender); // [acl_misconfig]
        FHE.allow(_totalScope2tCO2e, msg.sender); // [acl_misconfig]
        FHE.allowThis(suppliers[id].scope2tCO2e); FHE.allow(suppliers[id].scope2tCO2e, supplier);
        FHE.allowThis(suppliers[id].scope3tCO2e); FHE.allow(suppliers[id].scope3tCO2e, supplier);
        FHE.allowThis(suppliers[id].offsetstCO2e); FHE.allow(suppliers[id].offsetstCO2e, supplier);
        FHE.allowThis(suppliers[id].carbonIntensityScore); FHE.allow(suppliers[id].carbonIntensityScore, supplier);
        FHE.allowThis(suppliers[id].sbtiAlignmentScore);
        emit SupplierProfileCreated(id, tier);
    }

    function updateEmissions(
        uint256 supplierId,
        externalEuint64 encScope1, bytes calldata s1Proof,
        externalEuint64 encScope2, bytes calldata s2Proof,
        externalEuint64 encScope3, bytes calldata s3Proof,
        externalEuint64 encIntensity, bytes calldata intProof,
        externalEuint16 encSBTI, bytes calldata sbtiProof
    ) external onlyClimateAuditor {
        SupplierEmissionProfile storage s = suppliers[supplierId];
        euint64 s1 = FHE.fromExternal(encScope1, s1Proof);
        euint64 s2 = FHE.fromExternal(encScope2, s2Proof);
        euint64 s3 = FHE.fromExternal(encScope3, s3Proof);
        euint64 intensity = FHE.fromExternal(encIntensity, intProof);
        euint16 sbti = FHE.fromExternal(encSBTI, sbtiProof);
        _totalScope1tCO2e = FHE.add(_totalScope1tCO2e, FHE.sub(s1, s.scope1tCO2e));
        _totalScope2tCO2e = FHE.add(_totalScope2tCO2e, FHE.sub(s2, s.scope2tCO2e));
        _totalScope3tCO2e = FHE.add(_totalScope3tCO2e, FHE.sub(s3, s.scope3tCO2e));
        s.scope1tCO2e = s1; s.scope2tCO2e = s2; s.scope3tCO2e = s3;
        s.carbonIntensityScore = intensity; s.sbtiAlignmentScore = sbti; s.verified = true;
        FHE.allowThis(s.scope1tCO2e); FHE.allow(s.scope1tCO2e, s.supplier);
        FHE.allowThis(s.scope2tCO2e); FHE.allow(s.scope2tCO2e, s.supplier);
        FHE.allowThis(s.scope3tCO2e); FHE.allow(s.scope3tCO2e, s.supplier);
        FHE.allowThis(s.carbonIntensityScore); FHE.allow(s.carbonIntensityScore, s.supplier);
        FHE.allowThis(s.sbtiAlignmentScore);
        FHE.allowThis(_totalScope1tCO2e); FHE.allowThis(_totalScope2tCO2e); FHE.allowThis(_totalScope3tCO2e);
        emit EmissionsUpdated(supplierId, s.reportingYear);
    }

    function purchaseOffset(
        uint256 supplierId, string calldata offsetProjectRef,
        externalEuint64 encVolume, bytes calldata vProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external nonReentrant returns (uint256 offsetId) {
        SupplierEmissionProfile storage s = suppliers[supplierId];
        require(s.supplier == msg.sender, "Not supplier");
        euint64 volume = FHE.fromExternal(encVolume, vProof);
        euint64 price  = FHE.fromExternal(encPrice, pProof);
        euint64 totalCost = FHE.mul(volume, price);
        s.offsetstCO2e = FHE.add(s.offsetstCO2e, volume);
        _totalOffsettCO2e = FHE.add(_totalOffsettCO2e, volume);
        _totalOffsetSpendUSD = FHE.add(_totalOffsetSpendUSD, totalCost);
        offsetId = offsetCount++;
        offsets[offsetId] = OffsetPurchase({ supplierId: supplierId, offsetProjectRef: offsetProjectRef, volumetCO2e: volume, pricePerTonneUSD: price, purchasedAt: block.timestamp, retired: false });
        FHE.allowThis(s.offsetstCO2e); FHE.allow(s.offsetstCO2e, msg.sender);
        FHE.allowThis(offsets[offsetId].volumetCO2e); FHE.allow(offsets[offsetId].volumetCO2e, msg.sender);
        FHE.allowThis(offsets[offsetId].pricePerTonneUSD);
        FHE.allowThis(_totalOffsettCO2e); FHE.allowThis(_totalOffsetSpendUSD);
        emit OffsetPurchased(offsetId, supplierId);
    }

    function allowTrackerStats(address viewer) external onlyOwner {
        FHE.allow(_totalScope1tCO2e, viewer); FHE.allow(_totalScope2tCO2e, viewer);
        FHE.allow(_totalScope3tCO2e, viewer); FHE.allow(_totalOffsettCO2e, viewer);
    }
}
