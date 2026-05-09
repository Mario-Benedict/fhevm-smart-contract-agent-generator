// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateSpaceResourceExtractionRights
/// @notice Encrypted space resource extraction licenses: confidential asteroid mining claims,
///         private orbital slot allocations, and encrypted resource value assessments.
///         Enables private bidding for extraterrestrial mineral rights.
contract PrivateSpaceResourceExtractionRights is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum ResourceType { WATER_ICE, IRON_NICKEL, PLATINUM_GROUP, RARE_EARTH, HELIUM3, REGOLITH }
    enum CelestialBodyType { ASTEROID, MOON, MARS, COMET, LAGRANGE_POINT }

    struct ExtractionLicense {
        address licensee;
        CelestialBodyType bodyType;
        ResourceType primaryResource;
        euint64 estimatedResourceTonnes;   // encrypted estimated resource mass
        euint64 estimatedValueUSD;          // encrypted estimated market value
        euint64 annualRoyaltyBps;           // encrypted royalty rate
        euint64 licenseFeePaidUSD;          // encrypted license acquisition cost
        euint64 extractionCapTonnesPerYear; // encrypted annual extraction cap
        euint64 extractedToDateTonnes;      // encrypted cumulative extraction
        bytes32 celestialBodyId;            // identifier for the body
        uint256 licenseGrantDate;
        uint256 licenseExpiryDate;
        bool active;
        bool suspended;
    }

    struct MiningBid {
        address bidder;
        bytes32 celestialBodyId;
        ResourceType resource;
        euint64 bidAmountUSD;              // encrypted bid amount
        euint64 proposedRoyaltyBps;        // encrypted proposed royalty
        euint64 technicalCapabilityScore;  // encrypted capability assessment
        euint64 environmentalRatingBps;    // encrypted sustainability score
        uint256 submittedAt;
        bool awarded;
        bool active;
    }

    struct ExtractionReport {
        uint256 licenseId;
        euint64 extractedThisPeriodTonnes; // encrypted period extraction
        euint64 resourceGradePercent;       // encrypted purity/grade
        euint64 royaltyDueUSD;             // encrypted royalty payment due
        uint256 reportingPeriodEnd;
        bool paid;
    }

    mapping(uint256 => ExtractionLicense) private licenses;
    mapping(uint256 => MiningBid) private bids;
    mapping(uint256 => ExtractionReport) private reports;
    mapping(address => bool) public isSpaceAgency;
    mapping(address => bool) public isLicensee;
    mapping(bytes32 => bool) public isClaimedBody;

    uint256 public licenseCount;
    uint256 public bidCount;
    uint256 public reportCount;
    euint64 private _totalLicensedResourceValue;
    euint64 private _totalRoyaltiesCollected;

    event LicenseGranted(uint256 indexed licenseId, address licensee, bytes32 bodyId);
    event BidSubmitted(uint256 indexed bidId, address bidder, bytes32 bodyId);
    event BidAwarded(uint256 indexed bidId, address winner);
    event ExtractionReported(uint256 indexed reportId, uint256 licenseId);
    event RoyaltyPaid(uint256 indexed reportId);

    constructor() Ownable(msg.sender) {
        _totalLicensedResourceValue = FHE.asEuint64(0);
        _totalRoyaltiesCollected = FHE.asEuint64(0);
        FHE.allowThis(_totalLicensedResourceValue);
        FHE.allowThis(_totalRoyaltiesCollected);
        isSpaceAgency[msg.sender] = true;
    }

    modifier onlySpaceAgency() { require(isSpaceAgency[msg.sender], "Not space agency"); _; }

    function submitMiningBid(
        bytes32 celestialBodyId,
        ResourceType resource,
        externalEuint64 encBidAmount, bytes calldata baProof,
        externalEuint64 encRoyalty, bytes calldata rProof,
        externalEuint64 encCapability, bytes calldata capProof,
        externalEuint64 encEnvironmental, bytes calldata envProof
    ) external nonReentrant returns (uint256 bidId) {
        require(!isClaimedBody[celestialBodyId], "Body already claimed");
        euint64 bidAmt = FHE.fromExternal(encBidAmount, baProof);
        euint64 royalty = FHE.fromExternal(encRoyalty, rProof);
        euint64 capability = FHE.fromExternal(encCapability, capProof);
        euint64 environmental = FHE.fromExternal(encEnvironmental, envProof);
        bidId = bidCount++;
        MiningBid storage mb = bids[bidId];
        mb.bidder = msg.sender;
        mb.celestialBodyId = celestialBodyId;
        mb.resource = resource;
        mb.bidAmountUSD = bidAmt;
        mb.proposedRoyaltyBps = royalty;
        mb.technicalCapabilityScore = capability;
        mb.environmentalRatingBps = environmental;
        mb.submittedAt = block.timestamp;
        mb.active = true;
        FHE.allowThis(mb.bidAmountUSD);
        FHE.allowThis(mb.proposedRoyaltyBps);
        FHE.allowThis(mb.technicalCapabilityScore);
        FHE.allow(mb.technicalCapabilityScore, msg.sender);
        FHE.allowThis(mb.environmentalRatingBps);
        emit BidSubmitted(bidId, msg.sender, celestialBodyId);
    }

    function awardLicense(
        uint256 bidId,
        externalEuint64 encEstResourceTonnes, bytes calldata ertProof,
        externalEuint64 encEstValue, bytes calldata evProof,
        externalEuint64 encExtractionCap, bytes calldata ecProof,
        uint256 expiryDate
    ) external onlySpaceAgency returns (uint256 licenseId) {
        MiningBid storage mb = bids[bidId];
        require(mb.active && !mb.awarded, "Invalid bid");
        require(!isClaimedBody[mb.celestialBodyId], "Already claimed");
        euint64 estTonnes = FHE.fromExternal(encEstResourceTonnes, ertProof);
        euint64 estValue = FHE.fromExternal(encEstValue, evProof);
        euint64 extractionCap = FHE.fromExternal(encExtractionCap, ecProof);
        licenseId = licenseCount++;
        ExtractionLicense storage el = licenses[licenseId];
        el.licensee = mb.bidder;
        el.bodyType = CelestialBodyType.ASTEROID; // default
        el.primaryResource = mb.resource;
        el.estimatedResourceTonnes = estTonnes;
        el.estimatedValueUSD = estValue;
        el.annualRoyaltyBps = mb.proposedRoyaltyBps;
        el.licenseFeePaidUSD = mb.bidAmountUSD;
        el.extractionCapTonnesPerYear = extractionCap;
        el.extractedToDateTonnes = FHE.asEuint64(0);
        el.celestialBodyId = mb.celestialBodyId;
        el.licenseGrantDate = block.timestamp;
        el.licenseExpiryDate = expiryDate;
        el.active = true;
        mb.awarded = true;
        isClaimedBody[mb.celestialBodyId] = true;
        isLicensee[mb.bidder] = true;
        _totalLicensedResourceValue = FHE.add(_totalLicensedResourceValue, estValue);
        FHE.allowThis(el.estimatedResourceTonnes);
        FHE.allow(el.estimatedResourceTonnes, mb.bidder);
        FHE.allowThis(el.estimatedValueUSD);
        FHE.allow(el.estimatedValueUSD, mb.bidder);
        FHE.allowThis(el.annualRoyaltyBps);
        FHE.allow(el.annualRoyaltyBps, mb.bidder);
        FHE.allowThis(el.extractionCapTonnesPerYear);
        FHE.allow(el.extractionCapTonnesPerYear, mb.bidder);
        FHE.allowThis(el.extractedToDateTonnes);
        FHE.allow(el.extractedToDateTonnes, mb.bidder);
        FHE.allowThis(_totalLicensedResourceValue);
        emit BidAwarded(bidId, mb.bidder);
        emit LicenseGranted(licenseId, mb.bidder, mb.celestialBodyId);
    }

    function submitExtractionReport(
        uint256 licenseId,
        externalEuint64 encExtracted, bytes calldata exProof,
        externalEuint64 encGrade, bytes calldata gProof,
        uint256 periodEnd,
        uint64 estimatedTonnesPlaintext
    ) external nonReentrant returns (uint256 reportId) {
        ExtractionLicense storage el = licenses[licenseId];
        require(el.licensee == msg.sender && el.active, "Not licensee");
        euint64 extracted = FHE.fromExternal(encExtracted, exProof);
        euint64 grade = FHE.fromExternal(encGrade, gProof);
        // Enforce annual extraction cap
        ebool withinCap = FHE.le(extracted, el.extractionCapTonnesPerYear);
        euint64 actualExtracted = FHE.select(withinCap, extracted, el.extractionCapTonnesPerYear);
        el.extractedToDateTonnes = FHE.add(el.extractedToDateTonnes, actualExtracted);
        // Calculate royalty: royaltyBps * (extracted tonnes * value per tonne)
        euint64 valuePerTonne = (estimatedTonnesPlaintext + 1) > 0
            ? FHE.div(el.estimatedValueUSD, estimatedTonnesPlaintext + 1)
            : FHE.asEuint64(0);
        euint64 extractionValue = FHE.mul(actualExtracted, valuePerTonne);
        euint64 royaltyDue = FHE.div(FHE.mul(extractionValue, el.annualRoyaltyBps), 10000);
        reportId = reportCount++;
        reports[reportId] = ExtractionReport({
            licenseId: licenseId, extractedThisPeriodTonnes: actualExtracted,
            resourceGradePercent: grade, royaltyDueUSD: royaltyDue,
            reportingPeriodEnd: periodEnd, paid: false
        });
        FHE.allowThis(reports[reportId].extractedThisPeriodTonnes);
        FHE.allow(reports[reportId].extractedThisPeriodTonnes, msg.sender);
        FHE.allowThis(reports[reportId].royaltyDueUSD);
        FHE.allow(reports[reportId].royaltyDueUSD, msg.sender);
        FHE.allowThis(el.extractedToDateTonnes);
        FHE.allow(el.extractedToDateTonnes, msg.sender);
        emit ExtractionReported(reportId, licenseId);
    }

    function payRoyalty(uint256 reportId) external onlySpaceAgency {
        ExtractionReport storage rpt = reports[reportId];
        require(!rpt.paid, "Already paid");
        rpt.paid = true;
        _totalRoyaltiesCollected = FHE.add(_totalRoyaltiesCollected, rpt.royaltyDueUSD);
        FHE.allowThis(_totalRoyaltiesCollected);
        emit RoyaltyPaid(reportId);
    }

    function addSpaceAgency(address sa) external onlyOwner { isSpaceAgency[sa] = true; }
    function allowResourceStats(address authority) external onlyOwner {
        FHE.allow(_totalLicensedResourceValue, authority);
        FHE.allow(_totalRoyaltiesCollected, authority);
    }
}
