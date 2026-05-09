// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialOrganDonorRegistry
/// @notice An organ donation registry where donor blood type, organ availability,
///         medical history scores, and transplant priority rankings remain encrypted.
///         Hospitals can run matching algorithms without seeing raw patient data.
contract ConfidentialOrganDonorRegistry is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct DonorProfile {
        euint32 bloodTypeCode;      // encrypted ABO/Rh code
        euint32 tissueMatchScore;   // HLA compatibility score
        euint8 organAvailBitmask;   // encrypted availability bitmap
        euint32 healthScore;        // overall organ health score
        euint32 ageGroupCode;       // encrypted age bracket
        bool registered;
        bool deceased;
        bool consentGiven;
        uint256 registrationDate;
    }

    struct RecipientProfile {
        euint32 bloodTypeCode;
        euint32 tissueRequirements;
        euint8 organsNeededMask;
        euint32 urgencyScore;       // higher = more urgent
        euint32 waitlistPosition;
        bool active;
        uint256 listingDate;
    }

    struct MatchRecord {
        address donor;
        address recipient;
        euint32 compatibilityScore;
        bool accepted;
        uint256 matchedAt;
    }

    mapping(address => DonorProfile) private donors;
    mapping(address => RecipientProfile) private recipients;
    mapping(bytes32 => MatchRecord) private matchRecords;
    address[] public donorList;
    address[] public recipientList;
    bytes32[] public matchList;

    euint64 private _totalMatchesAttempted;
    euint64 private _totalSuccessfulTransplants;

    event DonorRegistered(address indexed donor);
    event RecipientRegistered(address indexed recipient);
    event MatchProposed(bytes32 indexed matchId, address donor, address recipient);
    event MatchAccepted(bytes32 indexed matchId);

    constructor() Ownable(msg.sender) {
        _totalMatchesAttempted = FHE.asEuint64(0);
        _totalSuccessfulTransplants = FHE.asEuint64(0);
        FHE.allowThis(_totalMatchesAttempted);
        FHE.allowThis(_totalSuccessfulTransplants);
    }

    function registerDonor(
        externalEuint32 encBloodType, bytes calldata btProof,
        externalEuint32 encTissueScore, bytes calldata tsProof,
        externalEuint8 encOrganMask, bytes calldata omProof,
        externalEuint32 encHealth, bytes calldata hProof,
        externalEuint32 encAgeGroup, bytes calldata agProof
    ) external {
        require(!donors[msg.sender].registered, "Already registered");
        DonorProfile storage d = donors[msg.sender];
        d.bloodTypeCode = FHE.fromExternal(encBloodType, btProof);
        d.tissueMatchScore = FHE.fromExternal(encTissueScore, tsProof);
        d.organAvailBitmask = FHE.fromExternal(encOrganMask, omProof);
        d.healthScore = FHE.fromExternal(encHealth, hProof);
        d.ageGroupCode = FHE.fromExternal(encAgeGroup, agProof);
        d.registered = true;
        d.consentGiven = true;
        d.registrationDate = block.timestamp;
        FHE.allowThis(d.bloodTypeCode);
        FHE.allow(d.bloodTypeCode, msg.sender);
        FHE.allowThis(d.tissueMatchScore);
        FHE.allow(d.tissueMatchScore, msg.sender);
        FHE.allowThis(d.organAvailBitmask);
        FHE.allow(d.organAvailBitmask, msg.sender);
        FHE.allowThis(d.healthScore);
        FHE.allow(d.healthScore, msg.sender);
        FHE.allowThis(d.ageGroupCode);
        donorList.push(msg.sender);
        emit DonorRegistered(msg.sender);
    }

    function registerRecipient(
        address recipient,
        externalEuint32 encBloodType, bytes calldata btProof,
        externalEuint32 encTissueReq, bytes calldata trProof,
        externalEuint8 encOrganMask, bytes calldata omProof,
        externalEuint32 encUrgency, bytes calldata urgProof
    ) external onlyOwner {
        require(!recipients[recipient].active, "Already registered");
        RecipientProfile storage r = recipients[recipient];
        r.bloodTypeCode = FHE.fromExternal(encBloodType, btProof);
        r.tissueRequirements = FHE.fromExternal(encTissueReq, trProof);
        r.organsNeededMask = FHE.fromExternal(encOrganMask, omProof);
        r.urgencyScore = FHE.fromExternal(encUrgency, urgProof);
        r.waitlistPosition = FHE.asEuint32(uint32(recipientList.length + 1));
        r.active = true;
        r.listingDate = block.timestamp;
        FHE.allowThis(r.bloodTypeCode);
        FHE.allow(r.bloodTypeCode, recipient);
        FHE.allowThis(r.tissueRequirements);
        FHE.allowThis(r.organsNeededMask);
        FHE.allow(r.organsNeededMask, recipient);
        FHE.allowThis(r.urgencyScore);
        FHE.allow(r.urgencyScore, recipient);
        FHE.allowThis(r.waitlistPosition);
        FHE.allow(r.waitlistPosition, recipient);
        recipientList.push(recipient);
        emit RecipientRegistered(recipient);
    }

    function proposeMatch(
        address donor,
        address recipient,
        externalEuint32 encCompatScore, bytes calldata proof
    ) external onlyOwner returns (bytes32 matchId) {
        require(donors[donor].registered && !donors[donor].deceased, "Donor not available");
        require(recipients[recipient].active, "Recipient not active");
        matchId = keccak256(abi.encodePacked(donor, recipient, block.timestamp));
        matchRecords[matchId].donor = donor;
        matchRecords[matchId].recipient = recipient;
        matchRecords[matchId].compatibilityScore = FHE.fromExternal(encCompatScore, proof);
        matchRecords[matchId].matchedAt = block.timestamp;
        // Check blood type compatibility via FHE
        ebool bloodMatch = FHE.eq(donors[donor].bloodTypeCode, recipients[recipient].bloodTypeCode);
        _totalMatchesAttempted = FHE.add(_totalMatchesAttempted, FHE.asEuint64(1));
        FHE.allowThis(matchRecords[matchId].compatibilityScore);
        FHE.allow(matchRecords[matchId].compatibilityScore, donor);
        FHE.allow(matchRecords[matchId].compatibilityScore, recipient);
        FHE.allow(bloodMatch, donor);
        FHE.allow(bloodMatch, recipient);
        FHE.allowThis(_totalMatchesAttempted);
        matchList.push(matchId);
        emit MatchProposed(matchId, donor, recipient);
    }

    function acceptMatch(bytes32 matchId) external onlyOwner {
        matchRecords[matchId].accepted = true;
        donors[matchRecords[matchId].donor].deceased = true;
        recipients[matchRecords[matchId].recipient].active = false;
        _totalSuccessfulTransplants = FHE.add(_totalSuccessfulTransplants, FHE.asEuint64(1));
        FHE.allowThis(_totalSuccessfulTransplants);
        emit MatchAccepted(matchId);
    }

    function allowDonorProfile(address hospital) external {
        require(donors[msg.sender].registered && donors[msg.sender].consentGiven, "No consent");
        FHE.allow(donors[msg.sender].bloodTypeCode, hospital);
        FHE.allow(donors[msg.sender].organAvailBitmask, hospital);
        FHE.allow(donors[msg.sender].healthScore, hospital);
    }

    function allowRegistryStats(address viewer) external onlyOwner {
        FHE.allow(_totalMatchesAttempted, viewer);
        FHE.allow(_totalSuccessfulTransplants, viewer);
    }
}
