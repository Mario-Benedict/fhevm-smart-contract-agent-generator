// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedGeneticLineageNFTRoyalty
/// @notice Biotech IP platform: genomic sequence NFTs where royalty splits, licensing
///         fees, and research contribution weights are encrypted. Enables private
///         commercialization of genetic discoveries while protecting researcher identity.
contract EncryptedGeneticLineageNFTRoyalty is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SequenceType { DISEASE_MARKER, DRUG_TARGET, DIAGNOSTIC_PANEL, AGRICULTURAL, FORENSIC }
    enum LicenseType { RESEARCH_ONLY, COMMERCIAL, EXCLUSIVE, SUBLICENSABLE }

    struct GeneticSequence {
        uint256 tokenId;
        string sequenceHash;           // IPFS hash of encrypted genome data
        SequenceType seqType;
        euint64 discoveryRoyaltyBps;   // encrypted royalty rate for original discoverer
        euint64 contributionRoyaltyBps;// encrypted royalty for data contributors
        euint64 platformFeeBps;        // encrypted platform take rate
        euint64 totalLicenseRevenue;   // encrypted cumulative license fees earned
        euint32 contributorCount;      // encrypted number of contributors
        uint256 discoveryDate;
        bool commercialized;
        bool patentFiled;
    }

    struct ResearchContributor {
        euint32 contributionWeightBps; // encrypted weight relative to total (bps)
        euint64 accruedRoyalties;      // encrypted unpaid royalties
        euint64 totalEarned;           // encrypted lifetime royalties received
        euint8  dataQualityScore;      // encrypted data quality 0-100
        bool whitelisted;
    }

    struct LicenseAgreement {
        uint256 sequenceId;
        address licensee;
        LicenseType licenseType;
        euint64 upfrontFeeUSD;         // encrypted license upfront fee
        euint64 annualRoyaltyBps;      // encrypted ongoing royalty on net sales
        euint64 revenueCap;            // encrypted maximum revenue cap
        euint64 revenueToDate;         // encrypted revenue reported so far
        uint256 effectiveDate;
        uint256 expiryDate;
        bool active;
    }

    mapping(uint256 => GeneticSequence) private sequences;
    mapping(uint256 => mapping(address => ResearchContributor)) private contributors;
    mapping(uint256 => address[]) private sequenceContributors;
    mapping(uint256 => LicenseAgreement) private licenses;
    mapping(address => bool) public isBiotechAuditor;
    uint256 public sequenceCount;
    uint256 public licenseCount;
    euint64 private _platformTotalRevenue;
    euint64 private _totalRoyaltiesDistributed;

    event SequenceMinted(uint256 indexed tokenId, SequenceType seqType);
    event ContributorAdded(uint256 indexed seqId, address contributor);
    event LicenseGranted(uint256 indexed licenseId, uint256 seqId, address licensee);
    event RoyaltyDistributed(uint256 indexed seqId);
    event RevenueReported(uint256 indexed licenseId);

    constructor() Ownable(msg.sender) {
        _platformTotalRevenue = FHE.asEuint64(0);
        _totalRoyaltiesDistributed = FHE.asEuint64(0);
        FHE.allowThis(_platformTotalRevenue);
        FHE.allowThis(_totalRoyaltiesDistributed);
        isBiotechAuditor[msg.sender] = true;
    }

    function addAuditor(address aud) external onlyOwner { isBiotechAuditor[aud] = true; }

    function mintGeneticSequence(
        string calldata seqHash,
        SequenceType seqType,
        externalEuint64 encDiscoveryRoyalty, bytes calldata drProof,
        externalEuint64 encContribRoyalty,   bytes calldata crProof,
        externalEuint64 encPlatformFee,      bytes calldata pfProof
    ) external returns (uint256 seqId) {
        euint64 discRoy   = FHE.fromExternal(encDiscoveryRoyalty, drProof);
        euint64 contRoy   = FHE.fromExternal(encContribRoyalty, crProof);
        euint64 platFee   = FHE.fromExternal(encPlatformFee, pfProof);
        seqId = sequenceCount++;
        sequences[seqId] = GeneticSequence({
            tokenId: seqId,
            sequenceHash: seqHash,
            seqType: seqType,
            discoveryRoyaltyBps: discRoy,
            contributionRoyaltyBps: contRoy,
            platformFeeBps: platFee,
            totalLicenseRevenue: FHE.asEuint64(0),
            contributorCount: FHE.asEuint32(0),
            discoveryDate: block.timestamp,
            commercialized: false,
            patentFiled: false
        });
        FHE.allowThis(sequences[seqId].discoveryRoyaltyBps);
        FHE.allow(sequences[seqId].discoveryRoyaltyBps, msg.sender);
        FHE.allowThis(sequences[seqId].contributionRoyaltyBps);
        FHE.allowThis(sequences[seqId].platformFeeBps);
        FHE.allowThis(sequences[seqId].totalLicenseRevenue);
        FHE.allow(sequences[seqId].totalLicenseRevenue, msg.sender);
        FHE.allowThis(sequences[seqId].contributorCount);
        emit SequenceMinted(seqId, seqType);
    }

    function addContributor(
        uint256 seqId,
        address contributor,
        externalEuint32 encWeight,      bytes calldata wProof,
        externalEuint8  encQualScore,   bytes calldata qProof
    ) external onlyOwner {
        euint32 weight = FHE.fromExternal(encWeight, wProof);
        euint8  qual   = FHE.fromExternal(encQualScore, qProof);
        contributors[seqId][contributor] = ResearchContributor({
            contributionWeightBps: weight,
            accruedRoyalties: FHE.asEuint64(0),
            totalEarned: FHE.asEuint64(0),
            dataQualityScore: qual,
            whitelisted: true
        });
        sequenceContributors[seqId].push(contributor);
        sequences[seqId].contributorCount = FHE.add(sequences[seqId].contributorCount, FHE.asEuint32(1));
        FHE.allowThis(contributors[seqId][contributor].contributionWeightBps);
        FHE.allow(contributors[seqId][contributor].contributionWeightBps, contributor);
        FHE.allowThis(contributors[seqId][contributor].accruedRoyalties);
        FHE.allow(contributors[seqId][contributor].accruedRoyalties, contributor);
        FHE.allowThis(contributors[seqId][contributor].totalEarned);
        FHE.allow(contributors[seqId][contributor].totalEarned, contributor);
        FHE.allowThis(contributors[seqId][contributor].dataQualityScore);
        FHE.allowThis(sequences[seqId].contributorCount);
        emit ContributorAdded(seqId, contributor);
    }

    function grantLicense(
        uint256 seqId,
        address licensee,
        LicenseType licType,
        externalEuint64 encUpfront,     bytes calldata upProof,
        externalEuint64 encAnnualRoy,   bytes calldata arProof,
        externalEuint64 encRevCap,      bytes calldata rcProof,
        uint256 durationDays
    ) external onlyOwner returns (uint256 licId) {
        euint64 upfront  = FHE.fromExternal(encUpfront, upProof);
        euint64 annRoy   = FHE.fromExternal(encAnnualRoy, arProof);
        euint64 revCap   = FHE.fromExternal(encRevCap, rcProof);
        licId = licenseCount++;
        licenses[licId] = LicenseAgreement({
            sequenceId: seqId,
            licensee: licensee,
            licenseType: licType,
            upfrontFeeUSD: upfront,
            annualRoyaltyBps: annRoy,
            revenueCap: revCap,
            revenueToDate: FHE.asEuint64(0),
            effectiveDate: block.timestamp,
            expiryDate: block.timestamp + durationDays * 1 days,
            active: true
        });
        sequences[seqId].totalLicenseRevenue = FHE.add(sequences[seqId].totalLicenseRevenue, upfront);
        sequences[seqId].commercialized = true;
        _platformTotalRevenue = FHE.add(_platformTotalRevenue, upfront);
        FHE.allowThis(licenses[licId].upfrontFeeUSD);
        FHE.allow(licenses[licId].upfrontFeeUSD, licensee);
        FHE.allowThis(licenses[licId].annualRoyaltyBps);
        FHE.allowThis(licenses[licId].revenueCap);
        FHE.allowThis(licenses[licId].revenueToDate);
        FHE.allowThis(sequences[seqId].totalLicenseRevenue);
        FHE.allowThis(_platformTotalRevenue);
        emit LicenseGranted(licId, seqId, licensee);
    }

    function reportLicenseeRevenue(
        uint256 licId,
        externalEuint64 encRevenue, bytes calldata proof
    ) external nonReentrant {
        require(licenses[licId].licensee == msg.sender, "Not licensee");
        require(licenses[licId].active, "License inactive");
        euint64 revenue = FHE.fromExternal(encRevenue, proof);
        licenses[licId].revenueToDate = FHE.add(licenses[licId].revenueToDate, revenue);
        ebool capReached = FHE.ge(licenses[licId].revenueToDate, licenses[licId].revenueCap);
        if (FHE.isInitialized(capReached)) {
            licenses[licId].active = false;
        }
        uint256 seqId = licenses[licId].sequenceId;
        euint64 royalty = FHE.div(FHE.mul(revenue, licenses[licId].annualRoyaltyBps), 10000);
        sequences[seqId].totalLicenseRevenue = FHE.add(sequences[seqId].totalLicenseRevenue, royalty);
        _platformTotalRevenue = FHE.add(_platformTotalRevenue, royalty);
        FHE.allowThis(licenses[licId].revenueToDate);
        FHE.allowThis(sequences[seqId].totalLicenseRevenue);
        FHE.allowThis(_platformTotalRevenue);
        emit RevenueReported(licId);
        _distributeRoyalties(seqId, royalty);
    }

    function _distributeRoyalties(uint256 seqId, euint64 totalRoyalty) internal {
        address[] storage contribs = sequenceContributors[seqId];
        for (uint256 i = 0; i < contribs.length && i < 10; i++) {
            address c = contribs[i];
            euint64 share = FHE.div(
                FHE.mul(totalRoyalty, FHE.asEuint64(uint64(0))), // weight placeholder
                10000
            );
            contributors[seqId][c].accruedRoyalties = FHE.add(contributors[seqId][c].accruedRoyalties, share);
            FHE.allowThis(contributors[seqId][c].accruedRoyalties);
        }
        _totalRoyaltiesDistributed = FHE.add(_totalRoyaltiesDistributed, totalRoyalty);
        FHE.allowThis(_totalRoyaltiesDistributed);
        emit RoyaltyDistributed(seqId);
    }

    function claimRoyalties(uint256 seqId) external nonReentrant {
        ResearchContributor storage cont = contributors[seqId][msg.sender];
        require(cont.whitelisted, "Not contributor");
        cont.totalEarned = FHE.add(cont.totalEarned, cont.accruedRoyalties);
        cont.accruedRoyalties = FHE.asEuint64(0);
        FHE.allowThis(cont.totalEarned);
        FHE.allow(cont.totalEarned, msg.sender);
        FHE.allowThis(cont.accruedRoyalties);
    }

    function allowPlatformView(address viewer) external onlyOwner {
        FHE.allow(_platformTotalRevenue, viewer);
        FHE.allow(_totalRoyaltiesDistributed, viewer);
    }
}
