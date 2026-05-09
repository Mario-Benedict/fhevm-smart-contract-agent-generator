// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateGeneticDataVault
/// @notice Encrypted genomic data vault: hidden SNP profiles, private ancestry
///         percentages, confidential disease risk scores, and encrypted research
///         licensing with granular consent management.
contract PrivateGeneticDataVault is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ConsentScope { NoConsent, AncestryOnly, HealthResearch, CommercialResearch, FullAccess }

    struct GenomicProfile {
        address owner;
        string sampleRef;              // anonymized sample reference
        euint8  ancestryEuropeBps;     // encrypted ancestry component
        euint8  ancestryAsiaBps;       // encrypted ancestry component
        euint8  ancestryAfricaBps;     // encrypted ancestry component
        euint16 diseaseRiskScore;      // encrypted composite risk
        euint16 pharmacogenomicScore;  // encrypted drug response score
        euint8  consentScope;          // encrypted consent level
        euint64 licensingPriceUSD;     // encrypted data price
        uint256 createdAt;
        bool active;
    }

    struct GenomicLicense {
        uint256 profileId;
        address licensee;
        euint8  accessScope;           // encrypted scope granted
        euint64 feePaidUSD;            // encrypted fee paid
        uint256 grantedAt;
        uint256 expiryDate;
    }

    mapping(uint256 => GenomicProfile) private profiles;
    mapping(uint256 => GenomicLicense) private licenses;
    mapping(address => uint256) private ownerProfileId;
    mapping(address => bool) public isGenomicsResearcher;

    uint256 public profileCount;
    uint256 public licenseCount;
    euint64 private _totalResearchRevenue;
    euint64 private _totalLicensesIssued;

    event ProfileCreated(uint256 indexed id, address owner);
    event DataLicensed(uint256 indexed licenseId, uint256 profileId, address licensee);

    modifier onlyGenomicsResearcher() {
        require(isGenomicsResearcher[msg.sender] || msg.sender == owner(), "Not genomics researcher");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalResearchRevenue = FHE.asEuint64(0);
        _totalLicensesIssued = FHE.asEuint64(0);
        FHE.allowThis(_totalResearchRevenue);
        FHE.allowThis(_totalLicensesIssued);
        isGenomicsResearcher[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addResearcher(address r) external onlyOwner { isGenomicsResearcher[r] = true; }

    function createProfile(
        string calldata sampleRef,
        externalEuint8  encAncEurope,   bytes calldata aeProof,
        externalEuint8  encAncAsia,     bytes calldata aaProof,
        externalEuint8  encAncAfrica,   bytes calldata aafProof,
        externalEuint16 encDiseaseRisk, bytes calldata drProof,
        externalEuint16 encPharma,      bytes calldata phProof,
        externalEuint8  encConsent,     bytes calldata conProof,
        externalEuint64 encPrice,       bytes calldata prProof
    ) external whenNotPaused returns (uint256 id) {
        euint8  ancEurope   = FHE.fromExternal(encAncEurope, aeProof);
        euint8  ancAsia     = FHE.fromExternal(encAncAsia, aaProof);
        euint8  ancAfrica   = FHE.fromExternal(encAncAfrica, aafProof);
        euint16 diseaseRisk = FHE.fromExternal(encDiseaseRisk, drProof);
        euint16 pharma      = FHE.fromExternal(encPharma, phProof);
        euint8  consent     = FHE.fromExternal(encConsent, conProof);
        euint64 price       = FHE.fromExternal(encPrice, prProof);
        id = profileCount++;
        ownerProfileId[msg.sender] = id;
        profiles[id] = GenomicProfile({
            owner: msg.sender, sampleRef: sampleRef, ancestryEuropeBps: ancEurope,
            ancestryAsiaBps: ancAsia, ancestryAfricaBps: ancAfrica, diseaseRiskScore: diseaseRisk,
            pharmacogenomicScore: pharma, consentScope: consent, licensingPriceUSD: price,
            createdAt: block.timestamp, active: true
        });
        FHE.allowThis(profiles[id].ancestryEuropeBps); FHE.allow(profiles[id].ancestryEuropeBps, msg.sender);
        FHE.allowThis(profiles[id].ancestryAsiaBps); FHE.allow(profiles[id].ancestryAsiaBps, msg.sender);
        FHE.allowThis(profiles[id].ancestryAfricaBps); FHE.allow(profiles[id].ancestryAfricaBps, msg.sender);
        FHE.allowThis(profiles[id].diseaseRiskScore); FHE.allow(profiles[id].diseaseRiskScore, msg.sender);
        FHE.allowThis(profiles[id].pharmacogenomicScore); FHE.allow(profiles[id].pharmacogenomicScore, msg.sender);
        FHE.allowThis(profiles[id].consentScope); FHE.allow(profiles[id].consentScope, msg.sender);
        FHE.allowThis(profiles[id].licensingPriceUSD); FHE.allow(profiles[id].licensingPriceUSD, msg.sender);
        emit ProfileCreated(id, msg.sender);
    }

    function licenseGenomicData(uint256 profileId, uint256 durationDays) external onlyGenomicsResearcher whenNotPaused nonReentrant returns (uint256 licenseId) {
        GenomicProfile storage p = profiles[profileId];
        require(p.active, "Profile inactive");
        euint64 fee = p.licensingPriceUSD;
        euint64 ownerShare = FHE.div(FHE.mul(fee, 85), 100); // 85% to data owner
        euint64 platformShare = FHE.sub(fee, ownerShare);
        licenseId = licenseCount++;
        licenses[licenseId] = GenomicLicense({
            profileId: profileId, licensee: msg.sender, accessScope: p.consentScope,
            feePaidUSD: fee, grantedAt: block.timestamp, expiryDate: block.timestamp + durationDays * 1 days
        });
        _totalResearchRevenue = FHE.add(_totalResearchRevenue, platformShare);
        _totalLicensesIssued  = FHE.add(_totalLicensesIssued, FHE.asEuint64(1));
        FHE.allowThis(licenses[licenseId].accessScope); FHE.allow(licenses[licenseId].accessScope, msg.sender);
        FHE.allowThis(licenses[licenseId].feePaidUSD); FHE.allow(licenses[licenseId].feePaidUSD, msg.sender);
        FHE.allow(ownerShare, p.owner);
        FHE.allowThis(_totalResearchRevenue); FHE.allowThis(_totalLicensesIssued);
        emit DataLicensed(licenseId, profileId, msg.sender);
    }

    function grantResearcherAccess(uint256 profileId, address researcher) external {
        require(profiles[profileId].owner == msg.sender, "Not your profile");
        FHE.allow(profiles[profileId].diseaseRiskScore, researcher);
        FHE.allow(profiles[profileId].pharmacogenomicScore, researcher);
    }

    function allowVaultStats(address viewer) external onlyOwner {
        FHE.allow(_totalResearchRevenue, viewer); FHE.allow(_totalLicensesIssued, viewer);
    }
}
