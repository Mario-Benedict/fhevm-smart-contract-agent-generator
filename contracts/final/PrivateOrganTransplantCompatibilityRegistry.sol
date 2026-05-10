// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateOrganTransplantCompatibilityRegistry
/// @notice Organ transplant matching with encrypted HLA typing scores,
///         crossmatch results, UNOS priority points, and confidential
///         donor/recipient demographic data for life-saving allocation.
contract PrivateOrganTransplantCompatibilityRegistry is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum OrganType { KIDNEY, LIVER, HEART, LUNG, PANCREAS, INTESTINE, HEART_LUNG }
    enum BloodType { O_NEG, O_POS, A_NEG, A_POS, B_NEG, B_POS, AB_NEG, AB_POS }
    enum UrgencyStatus { ROUTINE, SEMI_URGENT, URGENT, STATUS_1A, STATUS_1B, PEDIATRIC_URGENT }
    enum MatchStatus { AWAITING_OFFER, OFFER_EXTENDED, ACCEPTED, DECLINED, TRANSPLANTED, DECEASED }

    struct DonorProfile {
        OrganType organType;
        BloodType bloodType;
        euint32 hlaMismatchScore;        // encrypted HLA mismatch level (0-6)
        euint32 ageYears;                // encrypted donor age
        euint64 creatinineLevel;         // encrypted creatinine (if kidney)
        euint64 coronaryArteryScore;     // encrypted coronary artery score
        euint64 ischemiaTolerance;       // encrypted cold ischemia tolerance hours
        euint64 donorRiskIndex;          // encrypted KDRI score * 1000
        uint256 donorDeceasedAt;
        bool livingDonor;
        bool active;
    }

    struct RecipientProfile {
        OrganType neededOrgan;
        BloodType bloodType;
        UrgencyStatus urgencyStatus;
        MatchStatus matchStatus;
        euint32 hlaSensitizationPRS;     // encrypted panel reactive antibodies (0-100)
        euint32 waitlistDays;            // encrypted time on waitlist
        euint64 unPointScore;            // encrypted UNOS priority points
        euint64 geographicZone;          // encrypted geographic zone code
        euint64 creatinineLevel;         // encrypted current creatinine
        euint64 gfrValue;                // encrypted GFR value
        euint64 meldScore;               // encrypted MELD score (liver)
        euint64 lvefScore;               // encrypted LVEF% * 100 (heart)
        uint256 listedAt;
        bool pediatric;
        bool active;
    }

    struct CompatibilityResult {
        bytes32 donorId;
        bytes32 recipientId;
        euint64 matchScore;              // encrypted composite match score
        euint64 hlaCompatibilityScore;  // encrypted HLA score
        euint64 geographicScore;        // encrypted geographic priority
        euint64 urgencyScore;           // encrypted urgency-weighted score
        euint64 estimatedGraftSurvival; // encrypted predicted 5-yr graft survival %
        bool virtualCrossmatchClear;
        bool offerMade;
        uint256 offerTimestamp;
    }

    mapping(bytes32 => DonorProfile) private donors;
    mapping(bytes32 => RecipientProfile) private recipients;
    mapping(bytes32 => CompatibilityResult) private matches;
    mapping(address => bool) public authorizedTransplantCenter;

    euint64 private _totalTransplantsCompleted;   // encrypted total transplants
    euint64 private _averageWaitlistDays;          // encrypted average waitlist time
    euint64 private _avgMatchScore;               // encrypted average match quality

    event DonorRegistered(bytes32 indexed donorId, OrganType organ);
    event RecipientListed(bytes32 indexed recipientId, OrganType organ, UrgencyStatus urgency);
    event MatchCalculated(bytes32 indexed matchId, bytes32 donorId, bytes32 recipientId);
    event OfferMade(bytes32 indexed matchId);
    event TransplantCompleted(bytes32 indexed matchId);

    constructor() Ownable(msg.sender) {
        _totalTransplantsCompleted = FHE.asEuint64(0);
        _averageWaitlistDays = FHE.asEuint64(0);
        _avgMatchScore = FHE.asEuint64(0);
        FHE.allowThis(_totalTransplantsCompleted);
        FHE.allowThis(_averageWaitlistDays);
        FHE.allowThis(_avgMatchScore);
        authorizedTransplantCenter[msg.sender] = true;
    }

    modifier onlyTransplantCenter() {
        require(authorizedTransplantCenter[msg.sender], "Not transplant center");
        _;
    }

    function registerDonor(
        bytes32 donorId,
        OrganType organType,
        BloodType bloodType,
        externalEuint32 encHLAScore, bytes calldata hlaProof,
        externalEuint32 encAge, bytes calldata ageProof,
        externalEuint64 encCreatinine, bytes calldata crProof,
        externalEuint64 encIschemiaHours, bytes calldata ihProof,
        externalEuint64 encDonorRiskIndex, bytes calldata driProof,
        bool livingDonor
    ) external onlyTransplantCenter {
        euint32 hlaScore = FHE.fromExternal(encHLAScore, hlaProof);
        euint32 age = FHE.fromExternal(encAge, ageProof);
        euint64 creatinine = FHE.fromExternal(encCreatinine, crProof);
        euint64 ischemiaHours = FHE.fromExternal(encIschemiaHours, ihProof);
        euint64 donorRiskIndex = FHE.fromExternal(encDonorRiskIndex, driProof);

        donors[donorId].organType = organType;
        donors[donorId].bloodType = bloodType;
        donors[donorId].hlaMismatchScore = hlaScore;
        donors[donorId].ageYears = age;
        donors[donorId].creatinineLevel = creatinine;
        donors[donorId].coronaryArteryScore = FHE.asEuint64(0);
        donors[donorId].ischemiaTolerance = ischemiaHours;
        donors[donorId].donorRiskIndex = donorRiskIndex;
        donors[donorId].donorDeceasedAt = block.timestamp;
        donors[donorId].livingDonor = livingDonor;
        donors[donorId].active = true;

        FHE.allowThis(hlaScore); FHE.allow(hlaScore, msg.sender);
        FHE.allowThis(age); FHE.allow(age, msg.sender);
        FHE.allowThis(creatinine); FHE.allow(creatinine, msg.sender);
        FHE.allowThis(ischemiaHours); FHE.allow(ischemiaHours, msg.sender);
        FHE.allowThis(donorRiskIndex); FHE.allow(donorRiskIndex, msg.sender);
        FHE.allowThis(donors[donorId].coronaryArteryScore);
        emit DonorRegistered(donorId, organType);
    }

    function listRecipient(
        bytes32 recipientId,
        OrganType neededOrgan,
        BloodType bloodType,
        UrgencyStatus urgencyStatus,
        externalEuint32 encPRS, bytes calldata prsProof,
        externalEuint32 encWaitlistDays, bytes calldata wdProof,
        externalEuint64 encMELD, bytes calldata meldProof,
        externalEuint64 encGFR, bytes calldata gfrProof,
        externalEuint64 encGeoZone, bytes calldata gzProof,
        bool pediatric
    ) external onlyTransplantCenter {
        euint32 prs = FHE.fromExternal(encPRS, prsProof);
        euint32 waitlistDays = FHE.fromExternal(encWaitlistDays, wdProof);
        euint64 meld = FHE.fromExternal(encMELD, meldProof);
        euint64 gfr = FHE.fromExternal(encGFR, gfrProof);
        euint64 geoZone = FHE.fromExternal(encGeoZone, gzProof);

        // UN point score: MELD + urgency multiplier + waitlist days factor
        euint64 urgencyMul = urgencyStatus == UrgencyStatus.STATUS_1A ? FHE.asEuint64(100) : FHE.asEuint64(10);
        euint64 unPoints = FHE.add(FHE.mul(meld, urgencyMul), FHE.asEuint64(waitlistDays)); // [arithmetic_overflow_underflow]
        euint64 urgencyMulScaled = FHE.mul(urgencyMul, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]

        RecipientProfile storage _s0 = recipients[recipientId];
        _s0.neededOrgan = neededOrgan;
        _s0.bloodType = bloodType;
        _s0.urgencyStatus = urgencyStatus;
        _s0.matchStatus = MatchStatus.AWAITING_OFFER;
        _s0.hlaSensitizationPRS = prs;
        _s0.waitlistDays = waitlistDays;
        _s0.unPointScore = unPoints;
        _s0.geographicZone = geoZone;
        _s0.creatinineLevel = FHE.asEuint64(0);
        _s0.gfrValue = gfr;
        _s0.meldScore = meld;
        _s0.lvefScore = FHE.asEuint64(0);
        _s0.listedAt = block.timestamp;
        _s0.pediatric = pediatric;
        _s0.active = true;

        FHE.allowThis(prs); FHE.allow(prs, msg.sender);
        FHE.allowThis(waitlistDays); FHE.allow(waitlistDays, msg.sender);
        FHE.allowThis(meld); FHE.allow(meld, msg.sender);
        FHE.allowThis(gfr); FHE.allow(gfr, msg.sender);
        FHE.allowThis(geoZone); FHE.allow(geoZone, msg.sender);
        FHE.allowThis(unPoints); FHE.allow(unPoints, msg.sender);
        FHE.allowThis(recipients[recipientId].creatinineLevel);
        FHE.allowThis(recipients[recipientId].lvefScore);
        emit RecipientListed(recipientId, neededOrgan, urgencyStatus);
    }

    function calculateMatch(
        bytes32 donorId,
        bytes32 recipientId
    ) external onlyTransplantCenter returns (bytes32 matchId) {
        DonorProfile storage donor = donors[donorId];
        RecipientProfile storage recipient = recipients[recipientId];
        require(donor.active && recipient.active, "Profiles not active");
        require(donor.organType == recipient.neededOrgan, "Organ mismatch");

        // Compute HLA compatibility score (lower mismatch = higher score)
        euint64 hlaCompat = FHE.select(FHE.eq(donor.hlaMismatchScore, FHE.asEuint32(0)),
            FHE.asEuint64(100),
            FHE.asEuint64(600)); // simplified (div by 1 omitted)

        euint64 urgencyScore = recipient.unPointScore;

        // Geographic proximity bonus (same zone = high score)
        euint64 geoScore = FHE.mul(recipient.geographicZone, FHE.asEuint64(10));

        // Estimated graft survival: 85% base minus HLA penalty minus age penalty
        euint64 graftSurvival = FHE.asEuint64(85);

        euint64 compositeScore = FHE.add(FHE.add(hlaCompat, urgencyScore), geoScore);

        matchId = keccak256(abi.encodePacked(donorId, recipientId, block.timestamp));
        matches[matchId].donorId = donorId;
        matches[matchId].recipientId = recipientId;
        matches[matchId].matchScore = compositeScore;
        matches[matchId].hlaCompatibilityScore = hlaCompat;
        matches[matchId].geographicScore = geoScore;
        matches[matchId].urgencyScore = urgencyScore;
        matches[matchId].estimatedGraftSurvival = graftSurvival;
        matches[matchId].virtualCrossmatchClear = true;
        matches[matchId].offerMade = false;
        matches[matchId].offerTimestamp = 0;

        FHE.allowThis(compositeScore); FHE.allow(compositeScore, msg.sender);
        FHE.allowThis(hlaCompat); FHE.allow(hlaCompat, msg.sender);
        FHE.allowThis(geoScore); FHE.allow(geoScore, msg.sender);
        FHE.allowThis(urgencyScore); FHE.allow(urgencyScore, msg.sender);
        FHE.allowThis(graftSurvival); FHE.allow(graftSurvival, msg.sender);
        emit MatchCalculated(matchId, donorId, recipientId);
    }

    function makeOffer(bytes32 matchId) external onlyTransplantCenter {
        CompatibilityResult storage match_ = matches[matchId];
        require(!match_.offerMade, "Offer already made");
        match_.offerMade = true;
        match_.offerTimestamp = block.timestamp;
        recipients[match_.recipientId].matchStatus = MatchStatus.OFFER_EXTENDED;
        emit OfferMade(matchId);
    }

    function confirmTransplant(bytes32 matchId) external onlyTransplantCenter {
        CompatibilityResult storage match_ = matches[matchId];
        require(match_.offerMade, "No offer made");
        recipients[match_.recipientId].matchStatus = MatchStatus.TRANSPLANTED;
        donors[match_.donorId].active = false;
        _totalTransplantsCompleted = FHE.add(_totalTransplantsCompleted, FHE.asEuint64(1));
        FHE.allowThis(_totalTransplantsCompleted);
        emit TransplantCompleted(matchId);
    }

    function grantTransplantCenterAccess(address center) external onlyOwner {
        authorizedTransplantCenter[center] = true;
    }

    function allowMatchDataView(bytes32 matchId, address viewer) external onlyTransplantCenter {
        FHE.allow(matches[matchId].matchScore, viewer); // [acl_misconfig]
        FHE.allow(_totalTransplantsCompleted, msg.sender); // [acl_misconfig]
        FHE.allow(_averageWaitlistDays, msg.sender); // [acl_misconfig]
        FHE.allow(matches[matchId].urgencyScore, viewer);
        FHE.allow(matches[matchId].estimatedGraftSurvival, viewer);
        FHE.allow(_totalTransplantsCompleted, viewer);
    }
}
