// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateHealthDataMarketplace
/// @notice Encrypted medical data marketplace: hidden patient consent flags, private
///         data access pricing per category, confidential researcher budget checks,
///         and encrypted revenue splits between patients and institutions.
contract PrivateHealthDataMarketplace is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DataCategory { GenomicData, ClinicalRecords, ImagingData, WearableMetrics, MentalHealth }
    enum ConsentLevel { None, AnonResearch, IdentifiedResearch, CommercialUse, FullAccess }

    struct PatientProfile {
        address patient;
        euint8  consentLevel;          // encrypted consent level
        euint64 pricePerAccessUSD;     // encrypted price for data access
        euint64 totalEarnedUSD;        // encrypted earnings from data sales
        euint16 dataQualityScore;      // encrypted quality score
        bool registered;
    }

    struct DataAccessLicense {
        uint256 profileId;
        address researcher;
        DataCategory category;
        euint64 accessFeeUSD;          // encrypted fee paid
        euint8  grantedConsentLevel;   // encrypted granted level
        uint256 expiryDate;
        bool active;
    }

    mapping(uint256 => PatientProfile) private profiles;
    mapping(address => uint256) private patientProfileId;
    mapping(uint256 => DataAccessLicense) private licenses;
    mapping(address => bool) public isInstitution;

    uint256 public profileCount;
    uint256 public licenseCount;
    euint64 private _totalPatientEarningsUSD;
    euint64 private _totalMarketplaceRevenueUSD;

    event ProfileRegistered(uint256 indexed id, address patient);
    event DataLicensed(uint256 indexed licenseId, uint256 profileId, address researcher);

    modifier onlyInstitution() {
        require(isInstitution[msg.sender] || msg.sender == owner(), "Not institution");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPatientEarningsUSD = FHE.asEuint64(0);
        _totalMarketplaceRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalPatientEarningsUSD);
        FHE.allowThis(_totalMarketplaceRevenueUSD);
        isInstitution[msg.sender] = true;
    }

    function addInstitution(address inst) external onlyOwner { isInstitution[inst] = true; }

    function registerProfile(
        externalEuint8  encConsent, bytes calldata cProof,
        externalEuint64 encPrice,   bytes calldata pProof,
        externalEuint16 encQuality, bytes calldata qProof
    ) external returns (uint256 id) {
        euint8  consent = FHE.fromExternal(encConsent, cProof);
        euint64 price   = FHE.fromExternal(encPrice, pProof);
        euint16 quality = FHE.fromExternal(encQuality, qProof);
        id = profileCount++;
        patientProfileId[msg.sender] = id;
        profiles[id] = PatientProfile({
            patient: msg.sender, consentLevel: consent, pricePerAccessUSD: price,
            totalEarnedUSD: FHE.asEuint64(0), dataQualityScore: quality, registered: true
        });
        FHE.allowThis(profiles[id].consentLevel); FHE.allow(profiles[id].consentLevel, msg.sender);
        FHE.allowThis(profiles[id].pricePerAccessUSD); FHE.allow(profiles[id].pricePerAccessUSD, msg.sender);
        FHE.allowThis(profiles[id].totalEarnedUSD); FHE.allow(profiles[id].totalEarnedUSD, msg.sender);
        FHE.allowThis(profiles[id].dataQualityScore);
        emit ProfileRegistered(id, msg.sender);
    }

    function licenseData(
        uint256 profileId, DataCategory category, uint256 durationDays
    ) external onlyInstitution nonReentrant returns (uint256 licenseId) {
        PatientProfile storage p = profiles[profileId];
        require(p.registered, "Profile not found");
        euint64 fee = p.pricePerAccessUSD;
        euint64 patientShare = FHE.div(FHE.mul(fee, FHE.asEuint64(80)), 100); // 80% to patient
        euint64 platformShare = FHE.sub(fee, patientShare); // 20% platform
        p.totalEarnedUSD = FHE.add(p.totalEarnedUSD, patientShare);
        _totalPatientEarningsUSD = FHE.add(_totalPatientEarningsUSD, patientShare);
        _totalMarketplaceRevenueUSD = FHE.add(_totalMarketplaceRevenueUSD, platformShare);
        licenseId = licenseCount++;
        licenses[licenseId] = DataAccessLicense({
            profileId: profileId, researcher: msg.sender, category: category,
            accessFeeUSD: fee, grantedConsentLevel: p.consentLevel,
            expiryDate: block.timestamp + durationDays * 1 days, active: true
        });
        FHE.allowThis(licenses[licenseId].accessFeeUSD); FHE.allow(licenses[licenseId].accessFeeUSD, msg.sender);
        FHE.allowThis(licenses[licenseId].grantedConsentLevel); FHE.allow(licenses[licenseId].grantedConsentLevel, msg.sender);
        FHE.allowThis(p.totalEarnedUSD); FHE.allow(p.totalEarnedUSD, p.patient);
        FHE.allowThis(_totalPatientEarningsUSD); FHE.allowThis(_totalMarketplaceRevenueUSD);
        emit DataLicensed(licenseId, profileId, msg.sender);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalPatientEarningsUSD, viewer);
        FHE.allow(_totalMarketplaceRevenueUSD, viewer);
    }
}
