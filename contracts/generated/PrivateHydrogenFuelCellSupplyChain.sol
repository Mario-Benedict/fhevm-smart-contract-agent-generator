// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateHydrogenFuelCellSupplyChain
/// @notice Green hydrogen production and fuel cell supply chain: encrypted electrolyser output,
///         confidential off-take agreements, hidden transport costs, and private certification
///         issuance for green hydrogen compliance.
contract PrivateHydrogenFuelCellSupplyChain is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum HydrogenGrade { GrayH2, BlueH2, GreenH2, TurquoiseH2 }
    enum CertStatus { Pending, Certified, Revoked }

    struct ElectrolyserPlant {
        address producer;
        string plantId;
        HydrogenGrade gradeType;
        euint32 installedCapacityKW;  // encrypted electrolyser capacity
        euint64 monthlyOutputKgH2;    // encrypted hydrogen output kg
        euint64 productionCostUSD;    // encrypted cost per kg
        euint64 offtakeAgreementUSD;  // encrypted off-take price per kg
        euint64 carbonCreditEarnedUSD;// encrypted carbon credit value
        bool operationalStatus;
    }

    struct OffTakeContract {
        uint256 plantId;
        address buyer;
        euint64 contractedVolumeKg;   // encrypted contracted volume
        euint64 pricePerKgUSD;        // encrypted agreed price
        euint64 deliveredVolumeKg;    // encrypted actual delivered volume
        euint64 totalInvoiceUSD;      // encrypted total invoice
        uint256 startDate;
        uint256 endDate;
        bool fulfilled;
    }

    mapping(uint256 => ElectrolyserPlant) private plants;
    mapping(uint256 => OffTakeContract) private offtakes;
    mapping(address => bool) public isCertifier;
    mapping(address => bool) public isTransporter;
    mapping(uint256 => CertStatus) public plantCertStatus;

    uint256 public plantCount;
    uint256 public offtakeCount;
    euint64 private _totalH2ProducedKg;
    euint64 private _totalCarbonCreditsUSD;
    euint64 private _totalOfftakeRevenueUSD;

    event PlantRegistered(uint256 indexed id, string plantId, HydrogenGrade grade);
    event OffTakeCreated(uint256 indexed id, uint256 plantId, address buyer);
    event DeliverySettled(uint256 indexed offtakeId);
    event CertificationUpdated(uint256 indexed plantId, CertStatus status);

    modifier onlyCertifier() {
        require(isCertifier[msg.sender] || msg.sender == owner(), "Not certifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalH2ProducedKg = FHE.asEuint64(0);
        _totalCarbonCreditsUSD = FHE.asEuint64(0);
        _totalOfftakeRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalH2ProducedKg);
        FHE.allowThis(_totalCarbonCreditsUSD);
        FHE.allowThis(_totalOfftakeRevenueUSD);
        isCertifier[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addCertifier(address c) external onlyOwner { isCertifier[c] = true; }
    function addTransporter(address t) external onlyOwner { isTransporter[t] = true; }

    function registerPlant(
        string calldata plantId,
        HydrogenGrade grade,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint64 encProdCost, bytes calldata costProof,
        externalEuint64 encOfftakePrice, bytes calldata otProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 cap = FHE.fromExternal(encCapacity, capProof);
        euint64 prodCost = FHE.fromExternal(encProdCost, costProof);
        euint64 offtakePrice = FHE.fromExternal(encOfftakePrice, otProof);
        id = plantCount++;
        plants[id] = ElectrolyserPlant({
            producer: msg.sender,
            plantId: plantId,
            gradeType: grade,
            installedCapacityKW: cap,
            monthlyOutputKgH2: FHE.asEuint64(0),
            productionCostUSD: prodCost,
            offtakeAgreementUSD: offtakePrice,
            carbonCreditEarnedUSD: FHE.asEuint64(0),
            operationalStatus: false
        });
        plantCertStatus[id] = CertStatus.Pending;
        FHE.allowThis(plants[id].installedCapacityKW); FHE.allow(plants[id].installedCapacityKW, msg.sender);
        FHE.allowThis(plants[id].monthlyOutputKgH2);
        FHE.allowThis(plants[id].productionCostUSD); FHE.allow(plants[id].productionCostUSD, msg.sender);
        FHE.allowThis(plants[id].offtakeAgreementUSD); FHE.allow(plants[id].offtakeAgreementUSD, msg.sender);
        FHE.allowThis(plants[id].carbonCreditEarnedUSD);
        emit PlantRegistered(id, plantId, grade);
    }

    function certifyPlant(uint256 plantId, bool approve) external onlyCertifier {
        plantCertStatus[plantId] = approve ? CertStatus.Certified : CertStatus.Revoked;
        if (approve) plants[plantId].operationalStatus = true;
        emit CertificationUpdated(plantId, plantCertStatus[plantId]);
    }

    function createOffTakeContract(
        uint256 plantId,
        address buyer,
        externalEuint64 encVolume, bytes calldata vProof,
        externalEuint64 encPricePerKg, bytes calldata pProof,
        uint256 durationDays
    ) external whenNotPaused returns (uint256 id) {
        ElectrolyserPlant storage p = plants[plantId];
        require(msg.sender == p.producer, "Not producer");
        require(plantCertStatus[plantId] == CertStatus.Certified, "Not certified");
        euint64 vol = FHE.fromExternal(encVolume, vProof);
        euint64 priceKg = FHE.fromExternal(encPricePerKg, pProof);
        euint64 totalInv = FHE.mul(vol, priceKg);
        id = offtakeCount++;
        offtakes[id] = OffTakeContract({
            plantId: plantId,
            buyer: buyer,
            contractedVolumeKg: vol,
            pricePerKgUSD: priceKg,
            deliveredVolumeKg: FHE.asEuint64(0),
            totalInvoiceUSD: totalInv,
            startDate: block.timestamp,
            endDate: block.timestamp + durationDays * 1 days,
            fulfilled: false
        });
        FHE.allowThis(offtakes[id].contractedVolumeKg); FHE.allow(offtakes[id].contractedVolumeKg, buyer); FHE.allow(offtakes[id].contractedVolumeKg, p.producer);
        FHE.allowThis(offtakes[id].pricePerKgUSD); FHE.allow(offtakes[id].pricePerKgUSD, buyer);
        FHE.allowThis(offtakes[id].deliveredVolumeKg);
        FHE.allowThis(offtakes[id].totalInvoiceUSD); FHE.allow(offtakes[id].totalInvoiceUSD, buyer); FHE.allow(offtakes[id].totalInvoiceUSD, p.producer);
        emit OffTakeCreated(id, plantId, buyer);
    }

    function reportDelivery(
        uint256 offtakeId,
        externalEuint64 encDeliveredKg, bytes calldata proof
    ) external nonReentrant {
        OffTakeContract storage ot = offtakes[offtakeId];
        require(isTransporter[msg.sender] || msg.sender == owner(), "Not transporter");
        require(!ot.fulfilled, "Already fulfilled");
        euint64 deliveredKg = FHE.fromExternal(encDeliveredKg, proof);
        ot.deliveredVolumeKg = deliveredKg;
        euint64 actualInvoice = FHE.mul(deliveredKg, ot.pricePerKgUSD);
        ot.totalInvoiceUSD = actualInvoice;
        ot.fulfilled = true;
        ElectrolyserPlant storage plant = plants[ot.plantId];
        plant.monthlyOutputKgH2 = FHE.add(plant.monthlyOutputKgH2, deliveredKg);
        _totalH2ProducedKg = FHE.add(_totalH2ProducedKg, deliveredKg);
        _totalOfftakeRevenueUSD = FHE.add(_totalOfftakeRevenueUSD, actualInvoice);
        FHE.allowThis(ot.deliveredVolumeKg); FHE.allow(ot.deliveredVolumeKg, ot.buyer);
        FHE.allowThis(ot.totalInvoiceUSD); FHE.allow(ot.totalInvoiceUSD, ot.buyer); FHE.allow(ot.totalInvoiceUSD, plant.producer);
        FHE.allowThis(plant.monthlyOutputKgH2);
        FHE.allowThis(_totalH2ProducedKg);
        FHE.allowThis(_totalOfftakeRevenueUSD);
        emit DeliverySettled(offtakeId);
    }

    function issueCarbonCredits(
        uint256 plantId,
        externalEuint64 encCreditValueUSD, bytes calldata proof
    ) external onlyCertifier {
        euint64 creditVal = FHE.fromExternal(encCreditValueUSD, proof);
        plants[plantId].carbonCreditEarnedUSD = FHE.add(plants[plantId].carbonCreditEarnedUSD, creditVal);
        _totalCarbonCreditsUSD = FHE.add(_totalCarbonCreditsUSD, creditVal);
        FHE.allowThis(plants[plantId].carbonCreditEarnedUSD);
        FHE.allow(plants[plantId].carbonCreditEarnedUSD, plants[plantId].producer);
        FHE.allowThis(_totalCarbonCreditsUSD);
    }

    function allowNetworkStats(address viewer) external onlyOwner {
        FHE.allow(_totalH2ProducedKg, viewer);
        FHE.allow(_totalCarbonCreditsUSD, viewer);
        FHE.allow(_totalOfftakeRevenueUSD, viewer);
    }
}
