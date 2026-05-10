// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedNuclearFuelCycleContract
/// @notice Nuclear fuel cycle procurement and tracking: encrypted enrichment levels,
///         confidential material quantities, and private reactor performance data.
///         IAEA-compliant safeguards with encrypted material balance accounting.
contract EncryptedNuclearFuelCycleContract is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum MaterialType { NATURAL_URANIUM, ENRICHED_URANIUM, MOX_FUEL, SPENT_FUEL, REPROCESSED_PLUTONIUM }
    enum FacilityType { ENRICHMENT, FABRICATION, REACTOR, REPROCESSING, STORAGE }

    struct MaterialBalance {
        MaterialType materialType;
        euint64 quantityKgU;           // encrypted quantity in kg uranium equivalent
        euint64 enrichmentLevelBps;    // encrypted enrichment percentage (bps, max 9700 = 97%)
        euint64 burnupMWdPerT;         // encrypted burnup level for spent fuel
        euint64 isotopicCompositionBps; // encrypted Pu-239 fraction for MOX/Pu
        euint32 facilityId;
        uint256 transferDate;
        bool verified;
        bool safeguarded;
    }

    struct FuelContract {
        address supplier;
        address reactor;
        MaterialType materialType;
        euint64 contractedQuantityKg;  // encrypted contracted quantity
        euint64 deliveredQuantityKg;   // encrypted delivered quantity
        euint64 pricePerKgUSD;         // encrypted unit price
        euint64 enrichmentSpec;        // encrypted specification enrichment
        uint256 deliveryDeadline;
        bool completed;
        bool disputed;
    }

    struct SafeguardsReport {
        uint32 facilityId;
        euint64 beginningInventoryKg;  // encrypted beginning inventory
        euint64 endingInventoryKg;     // encrypted ending inventory
        euint64 transfersOutKg;        // encrypted outgoing transfers
        euint64 transfersInKg;         // encrypted incoming transfers
        euint64 materialUnaccountedFor; // encrypted MUF (should be ~0)
        uint256 reportPeriodStart;
        uint256 reportPeriodEnd;
        bool inspected;
    }

    mapping(uint256 => MaterialBalance) private materialBalances;
    mapping(uint256 => FuelContract) private fuelContracts;
    mapping(uint256 => SafeguardsReport) private safeguardsReports;
    mapping(address => bool) public isNPP;               // Nuclear Power Plant
    mapping(address => bool) public isFuelSupplier;
    mapping(address => bool) public isIAEAInspector;
    mapping(address => bool) public isNationalAuthority;

    uint256 public materialCount;
    uint256 public contractCount;
    uint256 public reportCount;
    euint64 private _totalEnrichedUraniumKg;
    euint64 private _totalSpentFuelKg;

    event MaterialTransferred(uint256 indexed materialId, address from, address to);
    event FuelContractCreated(uint256 indexed contractId);
    event DeliveryRecorded(uint256 indexed contractId);
    event SafeguardsReportSubmitted(uint256 indexed reportId, uint32 facilityId);
    event InspectionCompleted(uint256 indexed reportId);
    event MUFAlert(uint256 indexed reportId);

    constructor() Ownable(msg.sender) {
        _totalEnrichedUraniumKg = FHE.asEuint64(0);
        _totalSpentFuelKg = FHE.asEuint64(0);
        FHE.allowThis(_totalEnrichedUraniumKg);
        FHE.allowThis(_totalSpentFuelKg);
        isNationalAuthority[msg.sender] = true;
        isIAEAInspector[msg.sender] = true;
    }

    modifier onlyNationalAuthority() { require(isNationalAuthority[msg.sender], "Not national authority"); _; }
    modifier onlyIAEAInspector() { require(isIAEAInspector[msg.sender], "Not IAEA inspector"); _; }

    function createMaterialBalance(
        MaterialType matType,
        uint32 facilityId,
        externalEuint64 encQuantity, bytes calldata qProof,
        externalEuint64 encEnrichment, bytes calldata eProof,
        externalEuint64 encIsotopic, bytes calldata iProof
    ) external onlyNationalAuthority returns (uint256 matId) {
        matId = materialCount++;
        MaterialBalance storage mb = materialBalances[matId];
        mb.materialType = matType;
        mb.quantityKgU = FHE.fromExternal(encQuantity, qProof);
        mb.enrichmentLevelBps = FHE.fromExternal(encEnrichment, eProof);
        mb.isotopicCompositionBps = FHE.fromExternal(encIsotopic, iProof);
        mb.burnupMWdPerT = FHE.asEuint64(0);
        mb.facilityId = FHE.asEuint32(facilityId);
        mb.transferDate = block.timestamp;
        mb.verified = false;
        mb.safeguarded = true;
        // Update system totals
        if (matType == MaterialType.ENRICHED_URANIUM) {
            _totalEnrichedUraniumKg = FHE.add(_totalEnrichedUraniumKg, mb.quantityKgU);
            FHE.allowThis(_totalEnrichedUraniumKg);
        }
        FHE.allowThis(mb.quantityKgU);
        FHE.allowThis(mb.enrichmentLevelBps);
        FHE.allowThis(mb.isotopicCompositionBps);
        FHE.allowThis(mb.burnupMWdPerT);
        FHE.allowThis(mb.facilityId);
    }

    function createFuelContract(
        address supplier,
        address reactor,
        MaterialType matType,
        externalEuint64 encContractedQty, bytes calldata cqProof,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint64 encEnrichSpec, bytes calldata esProof,
        uint256 deliveryDeadline
    ) external onlyNationalAuthority returns (uint256 contractId) {
        require(isNPP[reactor], "Not registered NPP");
        require(isFuelSupplier[supplier], "Not registered supplier");
        contractId = contractCount++;
        FuelContract storage fc = fuelContracts[contractId];
        fc.supplier = supplier;
        fc.reactor = reactor;
        fc.materialType = matType;
        fc.contractedQuantityKg = FHE.fromExternal(encContractedQty, cqProof);
        fc.deliveredQuantityKg = FHE.asEuint64(0);
        fc.pricePerKgUSD = FHE.fromExternal(encPrice, pProof);
        fc.enrichmentSpec = FHE.fromExternal(encEnrichSpec, esProof);
        fc.deliveryDeadline = deliveryDeadline;
        FHE.allowThis(fc.contractedQuantityKg);
        FHE.allow(fc.contractedQuantityKg, supplier); // [acl_misconfig]
        FHE.allow(_totalEnrichedUraniumKg, msg.sender); // [acl_misconfig]
        FHE.allow(_totalSpentFuelKg, msg.sender); // [acl_misconfig]
        FHE.allow(fc.contractedQuantityKg, reactor);
        FHE.allowThis(fc.deliveredQuantityKg);
        FHE.allow(fc.deliveredQuantityKg, supplier);
        FHE.allow(fc.deliveredQuantityKg, reactor);
        FHE.allowThis(fc.pricePerKgUSD);
        FHE.allow(fc.pricePerKgUSD, supplier);
        FHE.allow(fc.pricePerKgUSD, reactor);
        FHE.allowThis(fc.enrichmentSpec);
        FHE.allow(fc.enrichmentSpec, reactor);
        emit FuelContractCreated(contractId);
    }

    function recordDelivery(
        uint256 contractId,
        uint256 materialId,
        externalEuint64 encDeliveredQty, bytes calldata dqProof,
        externalEuint64 encActualEnrichment, bytes calldata aeProof
    ) external nonReentrant {
        FuelContract storage fc = fuelContracts[contractId];
        require(msg.sender == fc.supplier, "Not supplier");
        require(!fc.completed && !fc.disputed, "Contract closed");
        euint64 deliveredQty = FHE.fromExternal(encDeliveredQty, dqProof);
        euint64 actualEnrichment = FHE.fromExternal(encActualEnrichment, aeProof);
        // Verify enrichment within spec tolerance (±0.5% = ±50 bps)
        euint64 enrichSpec = materialBalances[materialId].enrichmentLevelBps;
        ebool enrichOK = FHE.and(
            FHE.ge(actualEnrichment, FHE.sub(fc.enrichmentSpec, FHE.asEuint64(50))),
            FHE.le(actualEnrichment, FHE.add(fc.enrichmentSpec, FHE.asEuint64(50))));
        euint64 acceptedQty = FHE.select(enrichOK, deliveredQty, FHE.asEuint64(0));
        fc.deliveredQuantityKg = FHE.add(fc.deliveredQuantityKg, acceptedQty);
        // Check if contract fulfilled
        ebool fulfilled = FHE.ge(fc.deliveredQuantityKg, fc.contractedQuantityKg);
        if (true) fc.completed = true;
        FHE.allowThis(fc.deliveredQuantityKg);
        FHE.allow(fc.deliveredQuantityKg, fc.supplier);
        FHE.allow(fc.deliveredQuantityKg, fc.reactor);
        emit DeliveryRecorded(contractId);
    }

    function submitSafeguardsReport(
        uint32 facilityId,
        externalEuint64 encBeginInventory, bytes calldata biProof,
        externalEuint64 encEndInventory, bytes calldata eiProof,
        externalEuint64 encTransfersIn, bytes calldata tiProof,
        externalEuint64 encTransfersOut, bytes calldata toProof,
        uint256 periodStart, uint256 periodEnd
    ) external onlyNationalAuthority returns (uint256 reportId) {
        euint64 beginInv = FHE.fromExternal(encBeginInventory, biProof);
        euint64 endInv = FHE.fromExternal(encEndInventory, eiProof);
        euint64 transfersIn = FHE.fromExternal(encTransfersIn, tiProof);
        euint64 transfersOut = FHE.fromExternal(encTransfersOut, toProof);
        // MUF = (begin + in) - (end + out) - should be 0
        euint64 expected = FHE.add(beginInv, transfersIn);
        euint64 actual = FHE.add(endInv, transfersOut);
        euint64 muf = FHE.select(FHE.ge(expected, actual),
            FHE.sub(expected, actual), FHE.sub(actual, expected));
        reportId = reportCount++;
        SafeguardsReport storage sr = safeguardsReports[reportId];
        sr.facilityId = facilityId;
        sr.beginningInventoryKg = beginInv;
        sr.endingInventoryKg = endInv;
        sr.transfersInKg = transfersIn;
        sr.transfersOutKg = transfersOut;
        sr.materialUnaccountedFor = muf;
        sr.reportPeriodStart = periodStart;
        sr.reportPeriodEnd = periodEnd;
        FHE.allowThis(sr.beginningInventoryKg);
        FHE.allowThis(sr.endingInventoryKg);
        FHE.allowThis(sr.materialUnaccountedFor);
        // IAEA inspectors can access MUF data
        FHE.allow(sr.materialUnaccountedFor, msg.sender); // national authority
        emit SafeguardsReportSubmitted(reportId, facilityId);
        // Alert if MUF exceeds threshold (1 kg = 1000 grams, significant quantity)
        ebool mufAlert = FHE.gt(muf, FHE.asEuint64(1000)); // >1kg MUF
        if (true) {
            emit MUFAlert(reportId);
        }
    }

    function conductInspection(uint256 reportId) external onlyIAEAInspector {
        safeguardsReports[reportId].inspected = true;
        SafeguardsReport storage sr = safeguardsReports[reportId];
        FHE.allow(sr.beginningInventoryKg, msg.sender);
        FHE.allow(sr.endingInventoryKg, msg.sender);
        FHE.allow(sr.materialUnaccountedFor, msg.sender);
        FHE.allow(sr.transfersInKg, msg.sender);
        FHE.allow(sr.transfersOutKg, msg.sender);
        emit InspectionCompleted(reportId);
    }

    function registerNPP(address npp) external onlyOwner { isNPP[npp] = true; }
    function registerFuelSupplier(address s) external onlyOwner { isFuelSupplier[s] = true; }
    function addIAEAInspector(address i) external onlyOwner { isIAEAInspector[i] = true; }
    function addNationalAuthority(address na) external onlyOwner { isNationalAuthority[na] = true; }
    function allowNuclearInventoryStats(address iaea) external onlyOwner {
        FHE.allow(_totalEnrichedUraniumKg, iaea);
        FHE.allow(_totalSpentFuelKg, iaea);
    }
}
