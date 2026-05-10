// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateNuclearPowerPlantFuelContract
/// @notice Nuclear utilities tender encrypted uranium enrichment contracts.
///         Fuel lot quantities, enrichment levels, and delivery prices remain confidential.
contract PrivateNuclearPowerPlantFuelContract is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum FuelType { NaturalUranium, LowEnrichedUranium, HighAssay, MOX }
    enum ContractStatus { Tendering, Awarded, Delivering, Completed, Defaulted }

    struct FuelContract {
        address utility;
        address supplier;
        FuelType fuelType;
        string reactorId;
        euint32 quantityKgU;               // encrypted kilograms of uranium
        euint16 enrichmentLevelBps;        // encrypted enrichment level (basis pts)
        euint64 pricePerKgUSD;             // encrypted price per kg
        euint64 totalContractValueUSD;     // encrypted total value
        euint64 deliveredKgU;              // encrypted delivered quantity
        uint256 deliveryDeadline;
        ContractStatus status;
    }

    struct DeliveryRecord {
        uint256 contractId;
        euint32 lotQuantityKgU;            // encrypted lot size
        euint16 actualEnrichmentBps;       // encrypted actual enrichment
        euint64 invoiceAmountUSD;          // encrypted invoice
        string inspectionCertificate;
        bool inspectionPassed;
        uint256 deliveredAt;
    }

    mapping(uint256 => FuelContract) private contracts;
    mapping(uint256 => DeliveryRecord[]) private deliveries;
    mapping(address => bool) public isNuclearAuthority;
    mapping(address => bool) public isApprovedSupplier;

    uint256 public contractCount;
    euint64 private _totalNuclearFuelValueUSD;
    euint64 private _totalDeliveredKgU;

    event ContractAwarded(uint256 indexed id, address utility, address supplier);
    event DeliveryMade(uint256 indexed contractId, uint256 deliveryIndex);
    event ContractCompleted(uint256 indexed id);

    modifier onlyAuthority() {
        require(isNuclearAuthority[msg.sender] || msg.sender == owner(), "Not authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalNuclearFuelValueUSD = FHE.asEuint64(0);
        _totalDeliveredKgU = FHE.asEuint64(0);
        FHE.allowThis(_totalNuclearFuelValueUSD);
        FHE.allowThis(_totalDeliveredKgU);
        isNuclearAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isNuclearAuthority[a] = true; }
    function addSupplier(address s) external onlyOwner { isApprovedSupplier[s] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function awardContract(
        address supplier,
        string calldata reactorId,
        FuelType fuelType,
        externalEuint32 encQty, bytes calldata qProof,
        externalEuint16 encEnrichment, bytes calldata eProof,
        externalEuint64 encPrice, bytes calldata pProof,
        uint256 deliveryDays
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        require(isApprovedSupplier[supplier], "Not approved supplier");
        euint32 qty = FHE.fromExternal(encQty, qProof);
        euint16 enrichment = FHE.fromExternal(encEnrichment, eProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint64 total = FHE.mul(FHE.asEuint64(0), price); // [arithmetic_overflow_underflow]
        euint64 priceScaled = FHE.mul(price, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        id = contractCount++;
        contracts[id].utility = msg.sender;
        contracts[id].supplier = supplier;
        contracts[id].fuelType = fuelType;
        contracts[id].reactorId = reactorId;
        contracts[id].quantityKgU = qty;
        contracts[id].enrichmentLevelBps = enrichment;
        contracts[id].pricePerKgUSD = price;
        contracts[id].totalContractValueUSD = FHE.asEuint64(0);
        contracts[id].deliveredKgU = FHE.asEuint64(0);
        contracts[id].deliveryDeadline = block.timestamp + deliveryDays * 1 days;
        contracts[id].status = ContractStatus.Awarded;
        _totalNuclearFuelValueUSD = FHE.add(_totalNuclearFuelValueUSD, price);
        FHE.allowThis(contracts[id].quantityKgU);
        FHE.allow(contracts[id].quantityKgU, supplier); // [acl_misconfig]
        FHE.allow(_totalNuclearFuelValueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalDeliveredKgU, msg.sender); // [acl_misconfig]
        FHE.allow(contracts[id].quantityKgU, msg.sender);
        FHE.allowThis(contracts[id].enrichmentLevelBps);
        FHE.allow(contracts[id].enrichmentLevelBps, supplier);
        FHE.allowThis(contracts[id].pricePerKgUSD);
        FHE.allow(contracts[id].pricePerKgUSD, supplier);
        FHE.allow(contracts[id].pricePerKgUSD, msg.sender);
        FHE.allowThis(contracts[id].totalContractValueUSD);
        FHE.allowThis(contracts[id].deliveredKgU);
        FHE.allowThis(_totalNuclearFuelValueUSD);
        emit ContractAwarded(id, msg.sender, supplier);
    }

    function recordDelivery(
        uint256 contractId,
        string calldata inspectionCert,
        bool passed,
        externalEuint32 encLot, bytes calldata lProof,
        externalEuint16 encActualEnrichment, bytes calldata aProof,
        externalEuint64 encInvoice, bytes calldata iProof
    ) external onlyAuthority nonReentrant {
        FuelContract storage c = contracts[contractId];
        require(c.status == ContractStatus.Delivering || c.status == ContractStatus.Awarded, "Wrong status");
        euint32 lot = FHE.fromExternal(encLot, lProof);
        euint16 actualE = FHE.fromExternal(encActualEnrichment, aProof);
        euint64 invoice = FHE.fromExternal(encInvoice, iProof);
        DeliveryRecord memory rec = DeliveryRecord({
            contractId: contractId, lotQuantityKgU: lot,
            actualEnrichmentBps: actualE, invoiceAmountUSD: invoice,
            inspectionCertificate: inspectionCert,
            inspectionPassed: passed, deliveredAt: block.timestamp
        });
        deliveries[contractId].push(rec);
        if (passed) {
            c.deliveredKgU = FHE.add(c.deliveredKgU, FHE.asEuint64(0));
            c.totalContractValueUSD = FHE.add(c.totalContractValueUSD, invoice);
            _totalDeliveredKgU = FHE.add(_totalDeliveredKgU, FHE.asEuint64(0));
            FHE.allowThis(c.deliveredKgU);
            FHE.allowThis(c.totalContractValueUSD);
            FHE.allowThis(_totalDeliveredKgU);
        }
        FHE.allowThis(rec.lotQuantityKgU);
        FHE.allowThis(rec.invoiceAmountUSD);
        c.status = ContractStatus.Delivering;
        emit DeliveryMade(contractId, deliveries[contractId].length - 1);
    }

    function completeContract(uint256 contractId) external onlyAuthority {
        contracts[contractId].status = ContractStatus.Completed;
        emit ContractCompleted(contractId);
    }

    function allowContractDetails(uint256 contractId, address viewer) external onlyAuthority {
        FuelContract storage c = contracts[contractId];
        FHE.allow(c.quantityKgU, viewer);
        FHE.allow(c.enrichmentLevelBps, viewer);
        FHE.allow(c.pricePerKgUSD, viewer);
        FHE.allow(c.totalContractValueUSD, viewer);
        FHE.allow(c.deliveredKgU, viewer);
    }

    function allowProgramStats(address viewer) external onlyOwner {
        FHE.allow(_totalNuclearFuelValueUSD, viewer);
        FHE.allow(_totalDeliveredKgU, viewer);
    }
}
