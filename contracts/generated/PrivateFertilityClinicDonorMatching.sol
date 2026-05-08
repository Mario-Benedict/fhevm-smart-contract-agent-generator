// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateFertilityClinicDonorMatching
/// @notice IVF clinic system where donor genetic profiles, recipient medical histories,
///         compatibility scores, and treatment costs are fully encrypted.
///         Protects donor and recipient privacy during the matching process.
contract PrivateFertilityClinicDonorMatching is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DonorType { EGG_DONOR, SPERM_DONOR, EMBRYO_DONOR }
    enum MatchStatus { SEARCHING, MATCHED, TREATMENT_IN_PROGRESS, SUCCESSFUL, UNSUCCESSFUL }

    struct DonorProfile {
        DonorType donorType;
        euint8  geneticHealthScore;    // encrypted 0-100
        euint8  phenotypicMatchScore;  // encrypted
        euint16 anonymizedDonorId;     // encrypted internal ID
        euint64 compensationUSD;       // encrypted agreed compensation
        euint8  availableDonations;    // encrypted remaining allowed donations
        euint8  successfulDonations;   // encrypted past successful cycles
        bool anonymous;
        bool active;
    }

    struct RecipientProfile {
        euint8  medicalEligibilityScore; // encrypted AMH/FSH/other markers 0-100
        euint8  ageDecade;               // encrypted decade bracket (3=30s)
        euint16 anonymizedRecipientId;   // encrypted
        euint64 treatmentBudgetUSD;      // encrypted
        euint64 totalSpentUSD;           // encrypted
        MatchStatus status;
        bool registered;
    }

    struct MatchRecord {
        uint256 donorId;
        address recipient;
        euint8  compatibilityScore;    // encrypted 0-100 match score
        euint64 treatmentCostUSD;      // encrypted
        euint32 cycleAttempts;         // encrypted
        uint256 matchDate;
        MatchStatus status;
    }

    mapping(uint256 => DonorProfile) private donors;
    mapping(address => RecipientProfile) private recipients;
    mapping(uint256 => MatchRecord) private matches;
    mapping(address => bool) public isMedicalStaff;
    uint256 public donorCount;
    uint256 public matchCount;
    euint64 private _totalTreatmentRevenue;
    euint32 private _totalSuccessfulCycles;

    event DonorRegistered(uint256 indexed donorId, DonorType dtype);
    event RecipientRegistered(address indexed recipient);
    event MatchCreated(uint256 indexed matchId, address indexed recipient);
    event TreatmentOutcomeRecorded(uint256 indexed matchId, bool successful);

    constructor() Ownable(msg.sender) {
        _totalTreatmentRevenue = FHE.asEuint64(0);
        _totalSuccessfulCycles = FHE.asEuint32(0);
        FHE.allowThis(_totalTreatmentRevenue);
        FHE.allowThis(_totalSuccessfulCycles);
        isMedicalStaff[msg.sender] = true;
    }

    function addMedicalStaff(address staff) external onlyOwner { isMedicalStaff[staff] = true; }

    function registerDonor(
        DonorType dtype,
        externalEuint8  encHealth,   bytes calldata hProof,
        externalEuint8  encPhenotype,bytes calldata pProof,
        externalEuint64 encComp,     bytes calldata cProof,
        externalEuint8  encAvailable,bytes calldata aProof,
        bool anonymous
    ) external returns (uint256 donorId) {
        require(isMedicalStaff[msg.sender], "Not medical staff");
        euint8  health    = FHE.fromExternal(encHealth, hProof);
        euint8  phenotype = FHE.fromExternal(encPhenotype, pProof);
        euint64 comp      = FHE.fromExternal(encComp, cProof);
        euint8  available = FHE.fromExternal(encAvailable, aProof);
        donorId = donorCount++;
        donors[donorId] = DonorProfile({
            donorType: dtype,
            geneticHealthScore: health,
            phenotypicMatchScore: phenotype,
            anonymizedDonorId: FHE.asEuint16(uint16(donorId + 10000)),
            compensationUSD: comp,
            availableDonations: available,
            successfulDonations: FHE.asEuint8(0),
            anonymous: anonymous,
            active: true
        });
        FHE.allowThis(donors[donorId].geneticHealthScore);
        FHE.allowThis(donors[donorId].phenotypicMatchScore);
        FHE.allowThis(donors[donorId].anonymizedDonorId);
        FHE.allowThis(donors[donorId].compensationUSD);
        FHE.allowThis(donors[donorId].availableDonations);
        FHE.allowThis(donors[donorId].successfulDonations);
        emit DonorRegistered(donorId, dtype);
    }

    function registerRecipient(
        address recipient,
        externalEuint8  encEligibility,bytes calldata eProof,
        externalEuint8  encAgeDec,      bytes calldata ageProof,
        externalEuint64 encBudget,      bytes calldata bProof
    ) external {
        require(isMedicalStaff[msg.sender], "Not medical staff");
        euint8  elig   = FHE.fromExternal(encEligibility, eProof);
        euint8  age    = FHE.fromExternal(encAgeDec, ageProof);
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        recipients[recipient] = RecipientProfile({
            medicalEligibilityScore: elig,
            ageDecade: age,
            anonymizedRecipientId: FHE.asEuint16(uint16(uint160(recipient) % 10000 + 20000)),
            treatmentBudgetUSD: budget,
            totalSpentUSD: FHE.asEuint64(0),
            status: MatchStatus.SEARCHING,
            registered: true
        });
        FHE.allowThis(recipients[recipient].medicalEligibilityScore);
        FHE.allow(recipients[recipient].medicalEligibilityScore, recipient);
        FHE.allowThis(recipients[recipient].ageDecade);
        FHE.allowThis(recipients[recipient].treatmentBudgetUSD);
        FHE.allow(recipients[recipient].treatmentBudgetUSD, recipient);
        FHE.allowThis(recipients[recipient].totalSpentUSD);
        FHE.allow(recipients[recipient].totalSpentUSD, recipient);
        FHE.allowThis(recipients[recipient].anonymizedRecipientId);
        emit RecipientRegistered(recipient);
    }

    function createMatch(
        uint256 donorId,
        address recipient,
        externalEuint8  encCompatScore, bytes calldata csProof,
        externalEuint64 encTreatCost,   bytes calldata tcProof
    ) external returns (uint256 matchId) {
        require(isMedicalStaff[msg.sender], "Not medical staff");
        require(recipients[recipient].registered, "Recipient not registered");
        require(donors[donorId].active, "Donor not active");
        euint8  compat = FHE.fromExternal(encCompatScore, csProof);
        euint64 cost   = FHE.fromExternal(encTreatCost, tcProof);
        matchId = matchCount++;
        matches[matchId] = MatchRecord({
            donorId: donorId,
            recipient: recipient,
            compatibilityScore: compat,
            treatmentCostUSD: cost,
            cycleAttempts: FHE.asEuint32(0),
            matchDate: block.timestamp,
            status: MatchStatus.MATCHED
        });
        recipients[recipient].status = MatchStatus.MATCHED;
        _totalTreatmentRevenue = FHE.add(_totalTreatmentRevenue, cost);
        donors[donorId].availableDonations = FHE.sub(donors[donorId].availableDonations, FHE.asEuint8(1));
        FHE.allowThis(matches[matchId].compatibilityScore);
        FHE.allow(matches[matchId].compatibilityScore, recipient);
        FHE.allowThis(matches[matchId].treatmentCostUSD);
        FHE.allow(matches[matchId].treatmentCostUSD, recipient);
        FHE.allowThis(matches[matchId].cycleAttempts);
        FHE.allowThis(_totalTreatmentRevenue);
        FHE.allowThis(donors[donorId].availableDonations);
        emit MatchCreated(matchId, recipient);
    }

    function recordTreatmentOutcome(uint256 matchId, bool successful) external {
        require(isMedicalStaff[msg.sender], "Not medical staff");
        matches[matchId].status = successful ? MatchStatus.SUCCESSFUL : MatchStatus.UNSUCCESSFUL;
        matches[matchId].cycleAttempts = FHE.add(matches[matchId].cycleAttempts, FHE.asEuint32(1));
        if (successful) {
            _totalSuccessfulCycles = FHE.add(_totalSuccessfulCycles, FHE.asEuint32(1));
            donors[matches[matchId].donorId].successfulDonations = FHE.add(
                donors[matches[matchId].donorId].successfulDonations, FHE.asEuint8(1)
            );
            FHE.allowThis(donors[matches[matchId].donorId].successfulDonations);
            FHE.allowThis(_totalSuccessfulCycles);
        }
        FHE.allowThis(matches[matchId].cycleAttempts);
        emit TreatmentOutcomeRecorded(matchId, successful);
    }

    function allowClinicStats(address viewer) external onlyOwner {
        FHE.allow(_totalTreatmentRevenue, viewer);
        FHE.allow(_totalSuccessfulCycles, viewer);
    }
}
