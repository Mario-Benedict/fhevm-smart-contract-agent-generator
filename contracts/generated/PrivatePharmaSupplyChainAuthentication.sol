// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivatePharmaSupplyChainAuthentication
/// @notice Drug supply chain with encrypted batch authenticity scores,
///         cold chain compliance data, and distributor margins kept private.
contract PrivatePharmaSupplyChainAuthentication is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DrugClass { BIOLOGIC, SMALL_MOLECULE, VACCINE, CONTROLLED, OTC, GENERIC }
    enum SupplyStage { MANUFACTURER, WHOLESALER, DISTRIBUTOR, PHARMACY, HOSPITAL }

    struct DrugBatch {
        string serialNumber;
        string ndcCode;               // National Drug Code
        DrugClass drugClass;
        address manufacturer;
        euint64 manufacturerPrice;    // encrypted ex-factory price
        euint64 wholesalerPrice;      // encrypted wholesale price
        euint64 pharmacyPrice;        // encrypted pharmacy acquisition
        euint64 patientPrice;         // encrypted retail price
        euint8  authenticityScore;    // encrypted 0-100 (serialization verified)
        euint8  coldChainCompliance;  // encrypted temperature compliance 0-100
        euint32 quantityUnits;        // encrypted units in batch
        euint8  qualityReleaseScore;  // encrypted QC release score
        uint256 manufactureDate;
        uint256 expiryDate;
        bool recalled;
        bool authenticated;
    }

    struct DistributionEvent {
        uint256 batchId;
        SupplyStage fromStage;
        SupplyStage toStage;
        address fromParty;
        address toParty;
        euint64 transactionPrice;    // encrypted price at this stage
        euint64 marginUSD;           // encrypted margin earned
        euint32 quantityTransferred; // encrypted units moved
        euint8  handlingCompliance;  // encrypted handling score
        uint256 eventTimestamp;
        bool verified;
    }

    mapping(uint256 => DrugBatch) private batches;
    mapping(uint256 => DistributionEvent[]) private distributionHistory;
    mapping(address => bool) public isCertifiedDistributor;
    mapping(address => bool) public isRegulatoryAuthority;
    uint256 public batchCount;
    euint64 private _totalSupplyChainValue;
    euint64 private _totalAuthenticatedBatches;

    event BatchCreated(uint256 indexed batchId, string ndc, DrugClass dClass);
    event TransferRecorded(uint256 indexed batchId, SupplyStage to);
    event BatchRecalled(uint256 indexed batchId);
    event AuthenticationVerified(uint256 indexed batchId);

    constructor() Ownable(msg.sender) {
        _totalSupplyChainValue = FHE.asEuint64(0);
        _totalAuthenticatedBatches = FHE.asEuint64(0);
        FHE.allowThis(_totalSupplyChainValue);
        FHE.allowThis(_totalAuthenticatedBatches);
        isRegulatoryAuthority[msg.sender] = true;
    }

    function addDistributor(address d) external onlyOwner { isCertifiedDistributor[d] = true; }
    function addRegulator(address r) external onlyOwner { isRegulatoryAuthority[r] = true; }

    function createBatch(
        string calldata serial,
        string calldata ndc,
        DrugClass dClass,
        externalEuint64 encMfgPrice,  bytes calldata mpProof,
        externalEuint8  encAuth,      bytes calldata authProof,
        externalEuint8  encColdChain, bytes calldata ccProof,
        externalEuint32 encQty,       bytes calldata qProof,
        externalEuint8  encQCScore,   bytes calldata qcProof,
        uint256 manufactureDate,
        uint256 expiryDate
    ) external returns (uint256 batchId) {
        euint64 mfgPrice  = FHE.fromExternal(encMfgPrice, mpProof);
        euint8  auth      = FHE.fromExternal(encAuth, authProof);
        euint8  coldChain = FHE.fromExternal(encColdChain, ccProof);
        euint32 qty       = FHE.fromExternal(encQty, qProof);
        euint8  qcScore   = FHE.fromExternal(encQCScore, qcProof);
        batchId = batchCount++;
        batches[batchId] = DrugBatch({
            serialNumber: serial, ndcCode: ndc, drugClass: dClass,
            manufacturer: msg.sender,
            manufacturerPrice: mfgPrice, wholesalerPrice: FHE.asEuint64(0),
            pharmacyPrice: FHE.asEuint64(0), patientPrice: FHE.asEuint64(0),
            authenticityScore: auth, coldChainCompliance: coldChain,
            quantityUnits: qty, qualityReleaseScore: qcScore,
            manufactureDate: manufactureDate, expiryDate: expiryDate,
            recalled: false, authenticated: false
        });
        _totalSupplyChainValue = FHE.add(_totalSupplyChainValue, mfgPrice);
        FHE.allowThis(batches[batchId].manufacturerPrice);
        FHE.allow(batches[batchId].manufacturerPrice, msg.sender);
        FHE.allowThis(batches[batchId].wholesalerPrice);
        FHE.allowThis(batches[batchId].pharmacyPrice);
        FHE.allowThis(batches[batchId].patientPrice);
        FHE.allowThis(batches[batchId].authenticityScore);
        FHE.allowThis(batches[batchId].coldChainCompliance);
        FHE.allowThis(batches[batchId].quantityUnits);
        FHE.allow(batches[batchId].quantityUnits, msg.sender);
        FHE.allowThis(batches[batchId].qualityReleaseScore);
        FHE.allowThis(_totalSupplyChainValue);
        emit BatchCreated(batchId, ndc, dClass);
    }

    function recordTransfer(
        uint256 batchId,
        SupplyStage fromStage,
        SupplyStage toStage,
        address toParty,
        externalEuint64 encTransPrice, bytes calldata tpProof,
        externalEuint64 encMargin,     bytes calldata mProof,
        externalEuint32 encQtyXfer,    bytes calldata qProof,
        externalEuint8  encHandling,   bytes calldata hProof
    ) external {
        require(isCertifiedDistributor[msg.sender] || isRegulatoryAuthority[msg.sender], "Unauthorized");
        euint64 transPrice = FHE.fromExternal(encTransPrice, tpProof);
        euint64 margin     = FHE.fromExternal(encMargin, mProof);
        euint32 qty        = FHE.fromExternal(encQtyXfer, qProof);
        euint8  handling   = FHE.fromExternal(encHandling, hProof);
        DistributionEvent memory event_ = DistributionEvent({
            batchId: batchId, fromStage: fromStage, toStage: toStage,
            fromParty: msg.sender, toParty: toParty,
            transactionPrice: transPrice, marginUSD: margin,
            quantityTransferred: qty, handlingCompliance: handling,
            eventTimestamp: block.timestamp, verified: true
        });
        distributionHistory[batchId].push(event_);
        // Update pricing at each stage
        if (toStage == SupplyStage.WHOLESALER) {
            batches[batchId].wholesalerPrice = transPrice;
            FHE.allowThis(batches[batchId].wholesalerPrice);
        } else if (toStage == SupplyStage.PHARMACY || toStage == SupplyStage.HOSPITAL) {
            batches[batchId].pharmacyPrice = transPrice;
            FHE.allowThis(batches[batchId].pharmacyPrice);
        }
        FHE.allowThis(transPrice);
        FHE.allowThis(margin);
        FHE.allow(margin, msg.sender);
        emit TransferRecorded(batchId, toStage);
    }

    function authenticateBatch(uint256 batchId) external {
        require(isRegulatoryAuthority[msg.sender], "Not regulator");
        batches[batchId].authenticated = true;
        _totalAuthenticatedBatches = FHE.add(_totalAuthenticatedBatches, FHE.asEuint64(1));
        FHE.allowThis(_totalAuthenticatedBatches);
        emit AuthenticationVerified(batchId);
    }

    function recallBatch(uint256 batchId) external {
        require(isRegulatoryAuthority[msg.sender], "Not regulator");
        batches[batchId].recalled = true;
        emit BatchRecalled(batchId);
    }

    function allowRegulatorView(uint256 batchId, address viewer) external {
        require(isRegulatoryAuthority[msg.sender], "Not regulator");
        FHE.allow(batches[batchId].authenticityScore, viewer);
        FHE.allow(batches[batchId].coldChainCompliance, viewer);
        FHE.allow(batches[batchId].manufacturerPrice, viewer);
    }
}
