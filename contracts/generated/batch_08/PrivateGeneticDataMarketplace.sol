// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateGeneticDataMarketplace
/// @notice Genomics data marketplace: researchers purchase access to encrypted genetic
///         datasets from consenting donors. Encrypted ancestry scores and disease markers.
contract PrivateGeneticDataMarketplace is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum DataCategory { AncestryComposition, DiseaseRisk, PharmacogenomicsVariants, TraitPrediction }
    enum ConsentLevel { ResearchOnly, CommercialAllowed, RestrictedAcademic }

    struct GeneticDataset {
        address donor;
        DataCategory category;
        ConsentLevel consent;
        euint32 snpCount;              // encrypted variant count
        euint32 ancestryDiversityScore;// encrypted ancestry diversity
        euint32 qualityScore;          // encrypted dataset quality
        euint64 accessFeeUSD;          // encrypted per-access fee
        euint64 totalRevenueUSD;       // encrypted revenue earned
        uint256 contributionDate;
        bool active;
    }

    struct DataAccessLicense {
        uint256 datasetId;
        address researcher;
        euint64 paidFeeUSD;            // encrypted fee paid
        ConsentLevel grantedConsent;
        uint256 issuedAt;
        uint256 expiresAt;
        bool revoked;
    }

    mapping(uint256 => GeneticDataset) private datasets;
    mapping(uint256 => DataAccessLicense) private licenses;
    mapping(address => bool) public isApprovedResearcher;
    mapping(address => bool) public isIRBApproved;           // IRB ethics board
    mapping(uint256 => mapping(address => bool)) public hasAccess;

    uint256 public datasetCount;
    uint256 public licenseCount;
    euint64 private _totalMarketRevenue;
    euint64 private _totalDonorPayouts;

    event DatasetContributed(uint256 indexed id, DataCategory category);
    event AccessLicensed(uint256 indexed licenseId, uint256 datasetId, address researcher);
    event LicenseRevoked(uint256 indexed licenseId);

    modifier onlyIRB() {
        require(isIRBApproved[msg.sender] || msg.sender == owner(), "Not IRB approved");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalMarketRevenue = FHE.asEuint64(0);
        _totalDonorPayouts = FHE.asEuint64(0);
        FHE.allowThis(_totalMarketRevenue);
        FHE.allowThis(_totalDonorPayouts);
        isIRBApproved[msg.sender] = true;
    }

    function addResearcher(address r) external onlyOwner { isApprovedResearcher[r] = true; }
    function addIRB(address i) external onlyOwner { isIRBApproved[i] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function contributeDataset(
        DataCategory category, ConsentLevel consent,
        externalEuint32 encSNP, bytes calldata sProof,
        externalEuint32 encAncestry, bytes calldata aProof,
        externalEuint32 encQuality, bytes calldata qProof,
        externalEuint64 encFee, bytes calldata fProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 snp = FHE.fromExternal(encSNP, sProof);
        euint32 ancestry = FHE.fromExternal(encAncestry, aProof);
        euint32 quality = FHE.fromExternal(encQuality, qProof);
        euint64 fee = FHE.fromExternal(encFee, fProof);
        id = datasetCount++;
        datasets[id].donor = msg.sender;
        datasets[id].category = category;
        datasets[id].consent = consent;
        datasets[id].snpCount = snp;
        datasets[id].ancestryDiversityScore = ancestry;
        datasets[id].qualityScore = quality;
        datasets[id].accessFeeUSD = fee;
        datasets[id].totalRevenueUSD = FHE.asEuint64(0);
        datasets[id].contributionDate = block.timestamp;
        datasets[id].active = true;
        FHE.allowThis(datasets[id].snpCount); FHE.allow(datasets[id].snpCount, msg.sender);
        FHE.allowThis(datasets[id].ancestryDiversityScore); FHE.allow(datasets[id].ancestryDiversityScore, msg.sender);
        FHE.allowThis(datasets[id].qualityScore); FHE.allow(datasets[id].qualityScore, msg.sender);
        FHE.allowThis(datasets[id].accessFeeUSD); FHE.allow(datasets[id].accessFeeUSD, msg.sender);
        FHE.allowThis(datasets[id].totalRevenueUSD); FHE.allow(datasets[id].totalRevenueUSD, msg.sender);
        emit DatasetContributed(id, category);
    }

    function requestAccess(
        uint256 datasetId, uint256 accessDays
    ) external whenNotPaused nonReentrant onlyIRB returns (uint256 licenseId) {
        require(isApprovedResearcher[msg.sender], "Not approved researcher");
        GeneticDataset storage ds = datasets[datasetId];
        require(ds.active && !hasAccess[datasetId][msg.sender], "Not available or already licensed");
        licenseId = licenseCount++;
        licenses[licenseId] = DataAccessLicense({
            datasetId: datasetId, researcher: msg.sender,
            paidFeeUSD: ds.accessFeeUSD, grantedConsent: ds.consent,
            issuedAt: block.timestamp,
            expiresAt: block.timestamp + accessDays * 1 days,
            revoked: false
        });
        ds.totalRevenueUSD = FHE.add(ds.totalRevenueUSD, ds.accessFeeUSD);
        _totalMarketRevenue = FHE.add(_totalMarketRevenue, ds.accessFeeUSD);
        _totalDonorPayouts = FHE.add(_totalDonorPayouts, ds.accessFeeUSD);
        hasAccess[datasetId][msg.sender] = true;
        FHE.allowThis(licenses[licenseId].paidFeeUSD);
        FHE.allow(licenses[licenseId].paidFeeUSD, msg.sender);
        FHE.allow(licenses[licenseId].paidFeeUSD, ds.donor);
        FHE.allowThis(ds.totalRevenueUSD);
        FHE.allowThis(_totalMarketRevenue);
        FHE.allowThis(_totalDonorPayouts);
        // Grant data access
        FHE.allow(ds.snpCount, msg.sender);
        FHE.allow(ds.ancestryDiversityScore, msg.sender);
        FHE.allow(ds.qualityScore, msg.sender);
        emit AccessLicensed(licenseId, datasetId, msg.sender);
    }

    function revokeLicense(uint256 licenseId) external onlyIRB {
        licenses[licenseId].revoked = true;
        emit LicenseRevoked(licenseId);
    }

    function withdrawDataset(uint256 datasetId) external {
        require(datasets[datasetId].donor == msg.sender, "Not donor");
        datasets[datasetId].active = false;
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalMarketRevenue, viewer);
        FHE.allow(_totalDonorPayouts, viewer);
    }
}
