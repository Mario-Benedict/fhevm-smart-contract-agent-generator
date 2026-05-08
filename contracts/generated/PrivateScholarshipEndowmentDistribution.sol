// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateScholarshipEndowmentDistribution
/// @notice Encrypted university endowment scholarship distribution: hidden applicant
///         financial need scores, confidential merit ranking indices, private donor
///         intent matching scores, and encrypted award amounts per academic year.
contract PrivateScholarshipEndowmentDistribution is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ScholarshipType { NeedBased, MeritBased, AthleticAward, STEM_Focus, FirstGeneration, International }
    enum AwardStatus { Applied, UnderReview, Awarded, Declined, Renewed }

    struct ScholarshipApplication {
        address student;
        ScholarshipType scholarshipType;
        string studentRef;
        string major;
        euint16 financialNeedScoreBps; // encrypted financial need score
        euint16 academicMeritScoreBps; // encrypted academic merit score
        euint16 donorMatchScoreBps;    // encrypted donor intent match
        euint64 awardedAmountUSD;      // encrypted award
        euint16 expectedFamilyContribBps; // encrypted EFC
        AwardStatus status;
        uint256 appliedAt;
        uint256 academicYear;
    }

    struct EndowmentFund {
        string donorName;
        string fundName;
        euint64 principalUSD;          // encrypted principal
        euint64 annualDistributableUSD;// encrypted annual payout
        euint64 totalAwardedUSD;       // encrypted total awarded
        euint16 investmentReturnBps;   // encrypted return
        bool active;
    }

    mapping(uint256 => ScholarshipApplication) private applications;
    mapping(uint256 => EndowmentFund) private endowments;
    mapping(address => bool) public isFinancialAidOfficer;

    uint256 public applicationCount;
    uint256 public endowmentCount;
    euint64 private _totalScholarshipAwardedUSD;

    event ApplicationSubmitted(uint256 indexed id, ScholarshipType scholarshipType);
    event ScholarshipAwarded(uint256 indexed id, uint256 awardedAt);
    event EndowmentCreated(uint256 indexed id, string fundName);

    modifier onlyFinancialAidOfficer() {
        require(isFinancialAidOfficer[msg.sender] || msg.sender == owner(), "Not financial aid officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalScholarshipAwardedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalScholarshipAwardedUSD);
        isFinancialAidOfficer[msg.sender] = true;
    }

    function addFinancialAidOfficer(address fao) external onlyOwner { isFinancialAidOfficer[fao] = true; }

    function createEndowment(
        string calldata donorName, string calldata fundName,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encAnnualDist, bytes calldata adProof,
        externalEuint16 encReturn, bytes calldata retProof
    ) external onlyFinancialAidOfficer returns (uint256 id) {
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 annualDist = FHE.fromExternal(encAnnualDist, adProof);
        euint16 returnRate = FHE.fromExternal(encReturn, retProof);
        id = endowmentCount++;
        endowments[id] = EndowmentFund({
            donorName: donorName, fundName: fundName, principalUSD: principal,
            annualDistributableUSD: annualDist, totalAwardedUSD: FHE.asEuint64(0),
            investmentReturnBps: returnRate, active: true
        });
        FHE.allowThis(endowments[id].principalUSD); FHE.allow(endowments[id].principalUSD, msg.sender);
        FHE.allowThis(endowments[id].annualDistributableUSD); FHE.allow(endowments[id].annualDistributableUSD, msg.sender);
        FHE.allowThis(endowments[id].totalAwardedUSD); FHE.allow(endowments[id].totalAwardedUSD, msg.sender);
        FHE.allowThis(endowments[id].investmentReturnBps);
        emit EndowmentCreated(id, fundName);
    }

    function submitApplication(
        ScholarshipType scholarshipType, string calldata studentRef, string calldata major,
        externalEuint16 encFinNeed, bytes calldata fnProof,
        externalEuint16 encAcadMerit, bytes calldata amProof,
        externalEuint16 encDonorMatch, bytes calldata dmProof,
        externalEuint16 encEFC, bytes calldata efcProof,
        uint256 academicYear
    ) external returns (uint256 id) {
        euint16 finNeed = FHE.fromExternal(encFinNeed, fnProof);
        euint16 acadMerit = FHE.fromExternal(encAcadMerit, amProof);
        euint16 donorMatch = FHE.fromExternal(encDonorMatch, dmProof);
        euint16 efc = FHE.fromExternal(encEFC, efcProof);
        id = applicationCount++;
        applications[id] = ScholarshipApplication({
            student: msg.sender, scholarshipType: scholarshipType, studentRef: studentRef,
            major: major, financialNeedScoreBps: finNeed, academicMeritScoreBps: acadMerit,
            donorMatchScoreBps: donorMatch, awardedAmountUSD: FHE.asEuint64(0),
            expectedFamilyContribBps: efc, status: AwardStatus.Applied,
            appliedAt: block.timestamp, academicYear: academicYear
        });
        FHE.allowThis(applications[id].financialNeedScoreBps);
        FHE.allowThis(applications[id].academicMeritScoreBps);
        FHE.allowThis(applications[id].donorMatchScoreBps);
        FHE.allowThis(applications[id].awardedAmountUSD); FHE.allow(applications[id].awardedAmountUSD, msg.sender);
        FHE.allowThis(applications[id].expectedFamilyContribBps);
        emit ApplicationSubmitted(id, scholarshipType);
    }

    function awardScholarship(
        uint256 applicationId, uint256 endowmentId,
        externalEuint64 encAward, bytes calldata proof
    ) external onlyFinancialAidOfficer nonReentrant {
        ScholarshipApplication storage a = applications[applicationId];
        EndowmentFund storage e = endowments[endowmentId];
        euint64 award = FHE.fromExternal(encAward, proof);
        a.awardedAmountUSD = award;
        a.status = AwardStatus.Awarded;
        e.totalAwardedUSD = FHE.add(e.totalAwardedUSD, award);
        _totalScholarshipAwardedUSD = FHE.add(_totalScholarshipAwardedUSD, award);
        FHE.allowThis(a.awardedAmountUSD); FHE.allow(a.awardedAmountUSD, a.student);
        FHE.allowThis(e.totalAwardedUSD); FHE.allow(e.totalAwardedUSD, msg.sender);
        FHE.allowThis(_totalScholarshipAwardedUSD);
        emit ScholarshipAwarded(applicationId, block.timestamp);
    }

    function allowEndowmentStats(address viewer) external onlyOwner {
        FHE.allow(_totalScholarshipAwardedUSD, viewer);
    }
}
