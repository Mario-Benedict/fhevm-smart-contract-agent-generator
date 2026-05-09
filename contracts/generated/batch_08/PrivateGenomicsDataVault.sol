// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateGenomicsDataVault
/// @notice Genomics data vault: encrypted genome sequence hashes, encrypted trait
///         markers, patient-controlled access grants for research institutions.
contract PrivateGenomicsDataVault is ZamaEthereumConfig, Ownable {
    enum TraitCategory { Disease, Ancestry, Pharmacogenomics, Nutrition, Athletic }
    enum AccessLevel { None, Aggregate, Anonymized, Identified }

    struct GenomicProfile {
        euint8  diseaseRiskScore;       // encrypted disease predisposition 0-100
        euint8  ancestryEuropeanPct;    // encrypted European ancestry %
        euint8  ancestryAsianPct;       // encrypted Asian ancestry %
        euint8  pharmacogenomicsScore;  // encrypted drug metabolism score
        euint16 significantVariants;    // encrypted number of significant SNPs
        euint64 sequencingCostUSD;      // encrypted sequencing cost
        bool sequenced;
        uint256 sequencedAt;
    }

    struct ResearchConsent {
        address institution;
        TraitCategory[] categories;
        AccessLevel grantedLevel;
        euint64 compensationUSD;       // encrypted compensation for data use
        uint256 consentExpiry;
        bool active;
    }

    mapping(address => GenomicProfile) private profiles;
    mapping(address => mapping(address => ResearchConsent)) private consents;
    mapping(address => bool) public isGenomicsLab;
    mapping(address => bool) public isResearchInstitution;
    uint256 public totalProfiles;
    euint64 private _totalCompensationPaid;

    event ProfileCreated(address indexed patient);
    event ConsentGranted(address indexed patient, address indexed institution);
    event ConsentRevoked(address indexed patient, address indexed institution);
    event CompensationPaid(address indexed patient, address indexed institution);

    modifier onlyLab() {
        require(isGenomicsLab[msg.sender] || msg.sender == owner(), "Not lab");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCompensationPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalCompensationPaid);
        isGenomicsLab[msg.sender] = true;
    }

    function addLab(address l) external onlyOwner { isGenomicsLab[l] = true; }
    function addInstitution(address i) external onlyOwner { isResearchInstitution[i] = true; }

    function uploadGenomicProfile(
        address patient,
        externalEuint8 encDisease, bytes calldata dPf,
        externalEuint8 encEuropean, bytes calldata euPf,
        externalEuint8 encAsian, bytes calldata asPf,
        externalEuint8 encPharma, bytes calldata phPf,
        externalEuint16 encVariants, bytes calldata vPf,
        externalEuint64 encCost, bytes calldata cPf
    ) external onlyLab {
        euint8 disease = FHE.fromExternal(encDisease, dPf);
        euint8 european = FHE.fromExternal(encEuropean, euPf);
        euint8 asian = FHE.fromExternal(encAsian, asPf);
        euint8 pharma = FHE.fromExternal(encPharma, phPf);
        euint16 variants = FHE.fromExternal(encVariants, vPf);
        euint64 cost = FHE.fromExternal(encCost, cPf);
        profiles[patient] = GenomicProfile({
            diseaseRiskScore: disease, ancestryEuropeanPct: european, ancestryAsianPct: asian,
            pharmacogenomicsScore: pharma, significantVariants: variants, sequencingCostUSD: cost,
            sequenced: true, sequencedAt: block.timestamp
        });
        totalProfiles++;
        FHE.allowThis(profiles[patient].diseaseRiskScore);
        FHE.allow(profiles[patient].diseaseRiskScore, patient);
        FHE.allowThis(profiles[patient].ancestryEuropeanPct);
        FHE.allow(profiles[patient].ancestryEuropeanPct, patient);
        FHE.allowThis(profiles[patient].ancestryAsianPct);
        FHE.allow(profiles[patient].ancestryAsianPct, patient);
        FHE.allowThis(profiles[patient].pharmacogenomicsScore);
        FHE.allow(profiles[patient].pharmacogenomicsScore, patient);
        FHE.allowThis(profiles[patient].significantVariants);
        FHE.allow(profiles[patient].significantVariants, patient);
        FHE.allowThis(profiles[patient].sequencingCostUSD);
        FHE.allow(profiles[patient].sequencingCostUSD, patient);
        emit ProfileCreated(patient);
    }

    function grantConsent(
        address institution, AccessLevel level,
        TraitCategory[] calldata categories,
        externalEuint64 encCompensation, bytes calldata proof,
        uint256 expiryDays
    ) external {
        require(profiles[msg.sender].sequenced, "Not sequenced");
        require(isResearchInstitution[institution], "Not institution");
        euint64 compensation = FHE.fromExternal(encCompensation, proof);
        // Clear old consent
        consents[msg.sender][institution] = ResearchConsent({
            institution: institution, categories: categories,
            grantedLevel: level, compensationUSD: compensation,
            consentExpiry: block.timestamp + expiryDays * 1 days, active: true
        });
        FHE.allowThis(consents[msg.sender][institution].compensationUSD);
        FHE.allow(consents[msg.sender][institution].compensationUSD, msg.sender);
        FHE.allow(consents[msg.sender][institution].compensationUSD, institution);
        // Grant data access based on level
        if (level == AccessLevel.Identified || level == AccessLevel.Anonymized) {
            FHE.allow(profiles[msg.sender].diseaseRiskScore, institution);
            FHE.allow(profiles[msg.sender].pharmacogenomicsScore, institution);
        }
        if (level == AccessLevel.Identified) {
            FHE.allow(profiles[msg.sender].ancestryEuropeanPct, institution);
            FHE.allow(profiles[msg.sender].ancestryAsianPct, institution);
            FHE.allow(profiles[msg.sender].significantVariants, institution);
        }
        emit ConsentGranted(msg.sender, institution);
    }

    function revokeConsent(address institution) external {
        consents[msg.sender][institution].active = false;
        emit ConsentRevoked(msg.sender, institution);
    }

    function payCompensation(address patient, address institution) external {
        require(isResearchInstitution[msg.sender] || msg.sender == institution, "Unauthorized");
        ResearchConsent storage c = consents[patient][institution];
        require(c.active && block.timestamp < c.consentExpiry, "Consent inactive");
        euint64 comp = c.compensationUSD;
        _totalCompensationPaid = FHE.add(_totalCompensationPaid, comp);
        FHE.allowThis(_totalCompensationPaid);
        FHE.allow(comp, patient);
        emit CompensationPaid(patient, institution);
    }

    function allowProfileToLab(address patient, address lab) external onlyLab {
        FHE.allow(profiles[patient].diseaseRiskScore, lab);
        FHE.allow(profiles[patient].significantVariants, lab);
    }

    function allowProgramStats(address viewer) external onlyOwner {
        FHE.allow(_totalCompensationPaid, viewer);
    }
}
