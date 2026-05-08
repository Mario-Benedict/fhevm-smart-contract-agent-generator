// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateUniversityAdmissions
/// @notice University admissions with encrypted academic scores, encrypted financial aid,
///         and private ranking. Decisions revealed only to applicant and admission committee.
contract PrivateUniversityAdmissions is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum AdmissionDecision { Pending, Accepted, Waitlisted, Rejected }
    enum ProgramType { Undergraduate, Graduate, MBA, PhD, LLB }

    struct Application {
        address applicant;
        ProgramType program;
        string programName;
        euint16 satScore;              // encrypted SAT/GRE score
        euint8 gpaScore;               // encrypted GPA * 10 (e.g. 38 = 3.8)
        euint16 essayScore;            // encrypted essay evaluation score
        euint16 extracurricularScore;  // encrypted extracurricular score
        euint64 financialNeedUSD;      // encrypted family income (for aid calc)
        euint64 aidOfferedUSD;         // encrypted financial aid offer
        euint16 overallRanking;        // encrypted overall admission rank
        uint256 submittedAt;
        AdmissionDecision decision;
        bool aidCalculated;
    }

    mapping(uint256 => Application) private applications;
    mapping(address => uint256[]) private applicantApps;
    mapping(address => bool) public isAdmissionsOfficer;
    mapping(ProgramType => euint64) private _programAidBudget;
    mapping(ProgramType => euint64) private _programAidUsed;
    mapping(ProgramType => euint16) private _minRequiredScore;
    uint256 public applicationCount;
    uint256 public admissionsOpen;
    uint256 public admissionsClose;

    event ApplicationSubmitted(uint256 indexed id, address applicant, ProgramType program);
    event DecisionMade(uint256 indexed id, AdmissionDecision decision);
    event AidCalculated(uint256 indexed id);
    event AidOffered(uint256 indexed id, address applicant);

    modifier onlyOfficer() {
        require(isAdmissionsOfficer[msg.sender] || msg.sender == owner(), "Not officer");
        _;
    }

    modifier duringAdmissions() {
        require(block.timestamp >= admissionsOpen && block.timestamp <= admissionsClose, "Not open");
        _;
    }

    constructor(uint256 openTimestamp, uint256 closeTimestamp) Ownable(msg.sender) {
        admissionsOpen = openTimestamp;
        admissionsClose = closeTimestamp;
        isAdmissionsOfficer[msg.sender] = true;
    }

    function addOfficer(address o) external onlyOwner { isAdmissionsOfficer[o] = true; }

    function setProgramAidBudget(
        ProgramType program,
        externalEuint64 encBudget, bytes calldata proof,
        externalEuint16 encMinScore, bytes calldata sProof
    ) external onlyOfficer {
        euint64 budget = FHE.fromExternal(encBudget, proof);
        euint16 minScore = FHE.fromExternal(encMinScore, sProof);
        _programAidBudget[program] = budget;
        _programAidUsed[program] = FHE.asEuint64(0);
        _minRequiredScore[program] = minScore;
        FHE.allowThis(_programAidBudget[program]);
        FHE.allowThis(_programAidUsed[program]);
        FHE.allowThis(_minRequiredScore[program]);
    }

    function submitApplication(
        ProgramType program, string calldata programName,
        externalEuint16 encSAT, bytes calldata satProof,
        externalEuint8 encGPA, bytes calldata gpaProof,
        externalEuint16 encEssay, bytes calldata essayProof,
        externalEuint16 encExtra, bytes calldata extraProof,
        externalEuint64 encFamilyIncome, bytes calldata incomeProof
    ) external duringAdmissions nonReentrant returns (uint256 id) {
        euint16 sat = FHE.fromExternal(encSAT, satProof);
        euint8 gpa = FHE.fromExternal(encGPA, gpaProof);
        euint16 essay = FHE.fromExternal(encEssay, essayProof);
        euint16 extra = FHE.fromExternal(encExtra, extraProof);
        euint64 income = FHE.fromExternal(encFamilyIncome, incomeProof);
        id = applicationCount++;
        applications[id] = Application({
            applicant: msg.sender, program: program, programName: programName,
            satScore: sat, gpaScore: gpa, essayScore: essay, extracurricularScore: extra,
            financialNeedUSD: income, aidOfferedUSD: FHE.asEuint64(0),
            overallRanking: FHE.asEuint16(0),
            submittedAt: block.timestamp, decision: AdmissionDecision.Pending, aidCalculated: false
        });
        FHE.allowThis(applications[id].satScore);
        FHE.allow(applications[id].satScore, msg.sender);
        FHE.allowThis(applications[id].gpaScore);
        FHE.allow(applications[id].gpaScore, msg.sender);
        FHE.allowThis(applications[id].essayScore);
        FHE.allowThis(applications[id].extracurricularScore);
        FHE.allowThis(applications[id].financialNeedUSD);
        FHE.allowThis(applications[id].aidOfferedUSD);
        FHE.allow(applications[id].aidOfferedUSD, msg.sender);
        FHE.allowThis(applications[id].overallRanking);
        applicantApps[msg.sender].push(id);
        emit ApplicationSubmitted(id, msg.sender, program);
    }

    function scoreApplication(
        uint256 appId,
        externalEuint16 encRanking, bytes calldata proof
    ) external onlyOfficer {
        euint16 ranking = FHE.fromExternal(encRanking, proof);
        applications[appId].overallRanking = ranking;
        FHE.allowThis(applications[appId].overallRanking);
    }

    function makeDecision(uint256 appId, AdmissionDecision decision) external onlyOfficer {
        applications[appId].decision = decision;
        FHE.allow(applications[appId].overallRanking, applications[appId].applicant);
        emit DecisionMade(appId, decision);
    }

    function calculateAid(
        uint256 appId,
        externalEuint64 encAidOffer, bytes calldata proof
    ) external onlyOfficer {
        Application storage a = applications[appId];
        require(a.decision == AdmissionDecision.Accepted && !a.aidCalculated, "Invalid");
        euint64 aid = FHE.fromExternal(encAidOffer, proof);
        // Cap to remaining budget
        euint64 remaining = FHE.sub(_programAidBudget[a.program], _programAidUsed[a.program]);
        ebool withinBudget = FHE.le(aid, remaining);
        euint64 finalAid = FHE.select(withinBudget, aid, remaining);
        a.aidOfferedUSD = finalAid;
        _programAidUsed[a.program] = FHE.add(_programAidUsed[a.program], finalAid);
        a.aidCalculated = true;
        FHE.allowThis(a.aidOfferedUSD);
        FHE.allow(a.aidOfferedUSD, a.applicant);
        FHE.allowThis(_programAidUsed[a.program]);
        emit AidCalculated(appId);
        emit AidOffered(appId, a.applicant);
    }

    function allowApplicationDetails(uint256 appId, address viewer) external {
        Application storage a = applications[appId];
        require(msg.sender == a.applicant || isAdmissionsOfficer[msg.sender], "Unauthorized");
        FHE.allow(a.satScore, viewer);
        FHE.allow(a.gpaScore, viewer);
        FHE.allow(a.aidOfferedUSD, viewer);
        FHE.allow(a.overallRanking, viewer);
    }
}
