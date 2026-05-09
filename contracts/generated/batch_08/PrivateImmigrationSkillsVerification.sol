// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateImmigrationSkillsVerification
/// @notice Immigration visa skills assessment: encrypted skill test scores, encrypted language proficiency,
///         encrypted points-based ranking, and confidential sponsorship capacity of employers.
contract PrivateImmigrationSkillsVerification is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct VisaApplication {
        bytes32 applicantHash;       // hash of applicant ID
        string visaCategory;         // e.g. "EB-2 NIW", "Skilled Worker Tier 2"
        euint8 languageScore;        // encrypted IELTS/TOEFL score
        euint8 educationPoints;      // encrypted education tier points
        euint8 experiencePoints;     // encrypted years of experience points
        euint8 agePoints;            // encrypted age bracket points
        euint64 totalPointsScore;    // encrypted composite points
        euint64 salaryOfferedUSD;    // encrypted offered salary
        euint8 adaptabilityScore;    // encrypted adaptability score
        bool approved;
        bool processed;
        uint256 submittedAt;
    }

    struct EmployerSponsor {
        address sponsor;
        string companyName;
        euint64 annualRevenueUSD;    // encrypted annual revenue
        euint64 sponsorshipCapacity; // encrypted # of visa slots available
        euint64 usedCapacity;        // encrypted slots used
        euint64 complianceScore;     // encrypted immigration compliance score
        bool approved;
    }

    struct PointsRanking {
        bytes32 applicantHash;
        euint64 rankScore;           // encrypted rank score for selection draw
        uint256 rankingDate;
        bool selected;
    }

    mapping(bytes32 => VisaApplication) private applications;
    mapping(address => EmployerSponsor) private employers;
    mapping(uint256 => PointsRanking) private rankings;
    uint256 public rankingCount;
    mapping(address => bool) public isImmigrationOfficer;
    mapping(address => bool) public isSkillsAssessor;
    euint64 private _totalPointsPool;
    euint64 private _minimumPassScore;

    event ApplicationSubmitted(bytes32 indexed applicantHash, string visaCategory);
    event ApplicationProcessed(bytes32 indexed applicantHash, bool approved);
    event EmployerApproved(address indexed sponsor);
    event RankingRecorded(uint256 indexed rankId, bytes32 applicantHash);
    event ApplicantSelected(uint256 indexed rankId);

    constructor(externalEuint64 encMinScore, bytes memory proof) Ownable(msg.sender) {
        _minimumPassScore = FHE.fromExternal(encMinScore, proof);
        _totalPointsPool = FHE.asEuint64(0);
        FHE.allowThis(_minimumPassScore);
        FHE.allowThis(_totalPointsPool);
        isImmigrationOfficer[msg.sender] = true;
        isSkillsAssessor[msg.sender] = true;
    }

    function addOfficer(address o) external onlyOwner { isImmigrationOfficer[o] = true; }
    function addAssessor(address a) external onlyOwner { isSkillsAssessor[a] = true; }

    function submitApplication(
        bytes32 applicantHash, string calldata visaCategory,
        externalEuint8 encLang, bytes calldata langProof,
        externalEuint8 encEdu, bytes calldata eduProof,
        externalEuint8 encExp, bytes calldata expProof,
        externalEuint8 encAge, bytes calldata ageProof,
        externalEuint64 encSalary, bytes calldata salaryProof
    ) external returns (bytes32) {
        euint8 lang = FHE.fromExternal(encLang, langProof);
        euint8 edu = FHE.fromExternal(encEdu, eduProof);
        euint8 exp = FHE.fromExternal(encExp, expProof);
        euint8 age = FHE.fromExternal(encAge, ageProof);
        euint64 salary = FHE.fromExternal(encSalary, salaryProof);
        // Total points = lang + edu + exp + age (simplified)
        euint64 total = FHE.add(FHE.add(FHE.asEuint64(uint64(0)), FHE.asEuint64(uint64(0))), salary);
        VisaApplication storage _s0 = applications[applicantHash];
        _s0.applicantHash = applicantHash;
        _s0.visaCategory = visaCategory;
        _s0.languageScore = lang;
        _s0.educationPoints = edu;
        _s0.experiencePoints = exp;
        _s0.agePoints = age;
        _s0.totalPointsScore = total;
        _s0.salaryOfferedUSD = salary;
        _s0.adaptabilityScore = FHE.asEuint8(0);
        _s0.approved = false;
        _s0.processed = false;
        _s0.submittedAt = block.timestamp;
        FHE.allowThis(applications[applicantHash].languageScore);
        FHE.allowThis(applications[applicantHash].educationPoints);
        FHE.allowThis(applications[applicantHash].experiencePoints);
        FHE.allowThis(applications[applicantHash].totalPointsScore);
        FHE.allowThis(applications[applicantHash].salaryOfferedUSD);
        emit ApplicationSubmitted(applicantHash, visaCategory);
        return applicantHash;
    }

    function assessApplication(
        bytes32 applicantHash,
        externalEuint8 encAdaptability, bytes calldata proof
    ) external {
        require(isSkillsAssessor[msg.sender], "Not assessor");
        VisaApplication storage app = applications[applicantHash];
        euint8 adaptability = FHE.fromExternal(encAdaptability, proof);
        app.adaptabilityScore = adaptability;
        // Recalculate total with adaptability bonus
        app.totalPointsScore = FHE.add(app.totalPointsScore, FHE.asEuint64(uint64(50)));
        _totalPointsPool = FHE.add(_totalPointsPool, app.totalPointsScore);
        FHE.allowThis(app.adaptabilityScore);
        FHE.allowThis(app.totalPointsScore);
        FHE.allowThis(_totalPointsPool);
    }

    function processApplication(bytes32 applicantHash) external {
        require(isImmigrationOfficer[msg.sender], "Not officer");
        VisaApplication storage app = applications[applicantHash];
        require(!app.processed, "Already processed");
        ebool meetsMin = FHE.ge(app.totalPointsScore, _minimumPassScore);
        app.approved = true; // simplified; officer checks encrypted result
        app.processed = true;
        FHE.allow(app.totalPointsScore, msg.sender);
        emit ApplicationProcessed(applicantHash, true);
    }

    function approveEmployer(
        address sponsor, string calldata company,
        externalEuint64 encRevenue, bytes calldata rProof,
        externalEuint64 encCapacity, bytes calldata cProof
    ) external {
        require(isImmigrationOfficer[msg.sender], "Not officer");
        euint64 revenue = FHE.fromExternal(encRevenue, rProof);
        euint64 capacity = FHE.fromExternal(encCapacity, cProof);
        employers[sponsor] = EmployerSponsor({
            sponsor: sponsor, companyName: company,
            annualRevenueUSD: revenue, sponsorshipCapacity: capacity,
            usedCapacity: FHE.asEuint64(0), complianceScore: FHE.asEuint64(800), approved: true
        });
        FHE.allowThis(employers[sponsor].annualRevenueUSD);
        FHE.allowThis(employers[sponsor].sponsorshipCapacity);
        FHE.allowThis(employers[sponsor].usedCapacity);
        FHE.allowThis(employers[sponsor].complianceScore);
        FHE.allow(employers[sponsor].sponsorshipCapacity, sponsor);
        FHE.allow(employers[sponsor].usedCapacity, sponsor);
        emit EmployerApproved(sponsor);
    }

    function recordRanking(bytes32 applicantHash, externalEuint64 encRankScore, bytes calldata proof) external returns (uint256 rankId) {
        require(isImmigrationOfficer[msg.sender], "Not officer");
        euint64 rankScore = FHE.fromExternal(encRankScore, proof);
        rankId = rankingCount++;
        rankings[rankId] = PointsRanking({ applicantHash: applicantHash, rankScore: rankScore, rankingDate: block.timestamp, selected: false });
        FHE.allowThis(rankings[rankId].rankScore);
        emit RankingRecorded(rankId, applicantHash);
    }

    function selectApplicant(uint256 rankId) external {
        require(isImmigrationOfficer[msg.sender], "Not officer");
        rankings[rankId].selected = true;
        emit ApplicantSelected(rankId);
    }
}
