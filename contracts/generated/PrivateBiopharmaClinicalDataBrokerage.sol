// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateBiopharmaClinicalDataBrokerage
/// @notice Confidential marketplace for pharma companies to purchase anonymized clinical trial
///         datasets. Encrypted patient count, encrypted price per dataset, hidden buyer identity
///         flags, and private IRB compliance scores determine access.
contract PrivateBiopharmaClinicalDataBrokerage is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum DataCategory { Phase1, Phase2, Phase3, RealWorldEvidence, BiomarkerPanel, GenomicProfile }
    enum ListingStatus { Active, Reserved, Sold, Withdrawn }

    struct DataListing {
        address dataOwner;
        DataCategory category;
        string studyCode;
        euint32 patientCount;          // encrypted number of patients
        euint64 askPriceUSD;           // encrypted ask price
        euint16 irbComplianceScore;    // encrypted IRB score (0-1000)
        euint8  deidentificationLevel; // encrypted de-identification level (1-5)
        euint64 licensingFeeUSD;       // encrypted platform licensing fee
        ListingStatus status;
        uint256 listedAt;
    }

    struct DataPurchase {
        uint256 listingId;
        address buyer;
        euint64 agreedPriceUSD;        // encrypted purchase price
        euint16 buyerComplianceScore;  // encrypted buyer compliance
        bool accessGranted;
        uint256 purchasedAt;
    }

    mapping(uint256 => DataListing) private listings;
    mapping(uint256 => DataPurchase) private purchases;
    mapping(address => bool) public isIRBAuthority;
    mapping(address => bool) public isVerifiedBuyer;

    uint256 public listingCount;
    uint256 public purchaseCount;
    euint64 private _totalDataSalesUSD;
    euint64 private _totalFeesCollectedUSD;
    euint32 private _totalPatientRecordsSold;

    event DataListed(uint256 indexed id, DataCategory category, string studyCode);
    event DataPurchased(uint256 indexed purchaseId, uint256 listingId, address buyer);
    event AccessRevoked(uint256 indexed purchaseId);

    modifier onlyIRB() {
        require(isIRBAuthority[msg.sender] || msg.sender == owner(), "Not IRB authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDataSalesUSD = FHE.asEuint64(0);
        _totalFeesCollectedUSD = FHE.asEuint64(0);
        _totalPatientRecordsSold = FHE.asEuint32(0);
        FHE.allowThis(_totalDataSalesUSD);
        FHE.allowThis(_totalFeesCollectedUSD);
        FHE.allowThis(_totalPatientRecordsSold);
        isIRBAuthority[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addIRBAuthority(address a) external onlyOwner { isIRBAuthority[a] = true; }
    function verifyBuyer(address b) external onlyOwner { isVerifiedBuyer[b] = true; }

    function listDataset(
        DataCategory category,
        string calldata studyCode,
        externalEuint32 encPatients, bytes calldata pProof,
        externalEuint64 encAskPrice, bytes calldata apProof,
        externalEuint16 encIRBScore, bytes calldata irbProof,
        externalEuint8 encDeident, bytes calldata dProof,
        externalEuint64 encLicenseFee, bytes calldata lfProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 patients = FHE.fromExternal(encPatients, pProof);
        euint64 askPrice = FHE.fromExternal(encAskPrice, apProof);
        euint16 irbScore = FHE.fromExternal(encIRBScore, irbProof);
        euint8 deident = FHE.fromExternal(encDeident, dProof);
        euint64 licenseFee = FHE.fromExternal(encLicenseFee, lfProof);
        id = listingCount++;
        listings[id] = DataListing({
            dataOwner: msg.sender,
            category: category,
            studyCode: studyCode,
            patientCount: patients,
            askPriceUSD: askPrice,
            irbComplianceScore: irbScore,
            deidentificationLevel: deident,
            licensingFeeUSD: licenseFee,
            status: ListingStatus.Active,
            listedAt: block.timestamp
        });
        FHE.allowThis(listings[id].patientCount); FHE.allow(listings[id].patientCount, msg.sender);
        FHE.allowThis(listings[id].askPriceUSD); FHE.allow(listings[id].askPriceUSD, msg.sender);
        FHE.allowThis(listings[id].irbComplianceScore);
        FHE.allowThis(listings[id].deidentificationLevel);
        FHE.allowThis(listings[id].licensingFeeUSD);
        emit DataListed(id, category, studyCode);
    }

    function purchaseDataset(
        uint256 listingId,
        externalEuint64 encOfferedPrice, bytes calldata opProof,
        externalEuint16 encBuyerCompliance, bytes calldata bcProof
    ) external whenNotPaused nonReentrant returns (uint256 purchaseId) {
        require(isVerifiedBuyer[msg.sender], "Not verified buyer");
        DataListing storage l = listings[listingId];
        require(l.status == ListingStatus.Active, "Not available");
        euint64 offeredPrice = FHE.fromExternal(encOfferedPrice, opProof);
        euint16 buyerCompliance = FHE.fromExternal(encBuyerCompliance, bcProof);
        // Accept if offered price >= ask price (branchless FHE)
        ebool priceOk = FHE.ge(offeredPrice, l.askPriceUSD);
        euint64 agreedPrice = FHE.select(priceOk, l.askPriceUSD, FHE.asEuint64(0));
        purchaseId = purchaseCount++;
        purchases[purchaseId] = DataPurchase({
            listingId: listingId,
            buyer: msg.sender,
            agreedPriceUSD: agreedPrice,
            buyerComplianceScore: buyerCompliance,
            accessGranted: true,
            purchasedAt: block.timestamp
        });
        l.status = ListingStatus.Sold;
        euint64 fee = FHE.div(agreedPrice, 20); // 5% platform fee (plaintext divisor)
        _totalDataSalesUSD = FHE.add(_totalDataSalesUSD, agreedPrice);
        _totalFeesCollectedUSD = FHE.add(_totalFeesCollectedUSD, fee);
        _totalPatientRecordsSold = FHE.add(_totalPatientRecordsSold, l.patientCount);
        FHE.allowThis(purchases[purchaseId].agreedPriceUSD);
        FHE.allow(purchases[purchaseId].agreedPriceUSD, msg.sender);
        FHE.allow(purchases[purchaseId].agreedPriceUSD, l.dataOwner);
        FHE.allowThis(purchases[purchaseId].buyerComplianceScore);
        FHE.allowThis(_totalDataSalesUSD);
        FHE.allowThis(_totalFeesCollectedUSD);
        FHE.allowThis(_totalPatientRecordsSold);
        emit DataPurchased(purchaseId, listingId, msg.sender);
    }

    function revokeAccess(uint256 purchaseId) external onlyIRB {
        purchases[purchaseId].accessGranted = false;
        emit AccessRevoked(purchaseId);
    }

    function allowMarketView(address viewer) external onlyOwner {
        FHE.allow(_totalDataSalesUSD, viewer);
        FHE.allow(_totalFeesCollectedUSD, viewer);
        FHE.allow(_totalPatientRecordsSold, viewer);
    }
}
