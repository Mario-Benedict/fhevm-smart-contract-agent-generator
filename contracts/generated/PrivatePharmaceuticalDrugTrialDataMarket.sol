// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivatePharmaceuticalDrugTrialDataMarket
/// @notice Encrypted clinical trial data marketplace: hidden patient outcome data prices,
///         confidential site performance scores, private regulatory submission valuations,
///         and encrypted biomarker licensing revenues.
contract PrivatePharmaceuticalDrugTrialDataMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum TrialPhase { Phase1, Phase2, Phase3, Phase4, RWE }
    enum DataLicenseType { SingleStudy, TherapeuticArea, Portfolio, PlatformAccess }

    struct ClinicalDataset {
        address clinicalSite;
        address sponsor;
        TrialPhase trialPhase;
        string protocolRef;
        euint32 patientCount;          // encrypted enrolled patients
        euint64 dataLicenseFeeUSD;     // encrypted license fee
        euint16 sitePerformanceScore;  // encrypted site quality score
        euint64 biomarkerValueUSD;     // encrypted biomarker IP value
        euint64 regulatorySubmissionValue; // encrypted reg value
        euint16 patientRetentionRateBps;   // encrypted retention rate
        bool available;
    }

    struct DataLicense {
        uint256 datasetId;
        address buyer;
        DataLicenseType licenseType;
        euint64 licenseFeeUSD;         // encrypted fee paid
        uint256 licensedAt;
        uint256 expiryDate;
    }

    mapping(uint256 => ClinicalDataset) private datasets;
    mapping(uint256 => DataLicense) private dataLicenses;
    mapping(address => bool) public isTrialRegulator;

    uint256 public datasetCount;
    uint256 public licenseCount;
    euint64 private _totalDataMarketRevenueUSD;

    event DatasetListed(uint256 indexed id, TrialPhase phase, string protocolRef);
    event DataLicensed(uint256 indexed licenseId, uint256 datasetId, address buyer);

    modifier onlyTrialRegulator() {
        require(isTrialRegulator[msg.sender] || msg.sender == owner(), "Not trial regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDataMarketRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalDataMarketRevenueUSD);
        isTrialRegulator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addRegulator(address r) external onlyOwner { isTrialRegulator[r] = true; }

    function listClinicalDataset(
        address sponsor, TrialPhase trialPhase, string calldata protocolRef,
        externalEuint32 encPatients, bytes calldata pProof,
        externalEuint64 encLicenseFee, bytes calldata lfProof,
        externalEuint16 encSiteScore, bytes calldata ssProof,
        externalEuint64 encBiomarker, bytes calldata bmProof,
        externalEuint16 encRetention, bytes calldata retProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 patients = FHE.fromExternal(encPatients, pProof);
        euint64 licenseFee = FHE.fromExternal(encLicenseFee, lfProof);
        euint16 siteScore = FHE.fromExternal(encSiteScore, ssProof);
        euint64 biomarker = FHE.fromExternal(encBiomarker, bmProof);
        euint16 retention = FHE.fromExternal(encRetention, retProof);
        id = datasetCount++;
        datasets[id] = ClinicalDataset({
            clinicalSite: msg.sender, sponsor: sponsor, trialPhase: trialPhase,
            protocolRef: protocolRef, patientCount: patients, dataLicenseFeeUSD: licenseFee,
            sitePerformanceScore: siteScore, biomarkerValueUSD: biomarker,
            regulatorySubmissionValue: FHE.asEuint64(0), patientRetentionRateBps: retention, available: true
        });
        FHE.allowThis(datasets[id].patientCount); FHE.allow(datasets[id].patientCount, sponsor);
        FHE.allowThis(datasets[id].dataLicenseFeeUSD); FHE.allow(datasets[id].dataLicenseFeeUSD, msg.sender);
        FHE.allowThis(datasets[id].sitePerformanceScore); FHE.allow(datasets[id].sitePerformanceScore, sponsor);
        FHE.allowThis(datasets[id].biomarkerValueUSD); FHE.allow(datasets[id].biomarkerValueUSD, msg.sender);
        FHE.allowThis(datasets[id].patientRetentionRateBps);
        emit DatasetListed(id, trialPhase, protocolRef);
    }

    function licenseDataset(
        uint256 datasetId, DataLicenseType licenseType,
        uint256 durationDays
    ) external whenNotPaused nonReentrant returns (uint256 licenseId) {
        ClinicalDataset storage ds = datasets[datasetId];
        require(ds.available, "Dataset not available");
        licenseId = licenseCount++;
        dataLicenses[licenseId] = DataLicense({
            datasetId: datasetId, buyer: msg.sender, licenseType: licenseType,
            licenseFeeUSD: ds.dataLicenseFeeUSD, licensedAt: block.timestamp,
            expiryDate: block.timestamp + durationDays * 1 days
        });
        _totalDataMarketRevenueUSD = FHE.add(_totalDataMarketRevenueUSD, ds.dataLicenseFeeUSD);
        FHE.allowThis(dataLicenses[licenseId].licenseFeeUSD); FHE.allow(dataLicenses[licenseId].licenseFeeUSD, msg.sender); FHE.allow(dataLicenses[licenseId].licenseFeeUSD, ds.clinicalSite);
        FHE.allowThis(_totalDataMarketRevenueUSD);
        emit DataLicensed(licenseId, datasetId, msg.sender);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalDataMarketRevenueUSD, viewer);
    }
}
