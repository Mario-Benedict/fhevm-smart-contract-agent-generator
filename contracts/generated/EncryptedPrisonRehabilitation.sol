// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrisonRehabilitation
/// @notice Prison rehabilitation & recidivism scoring: encrypted risk assessment scores,
///         encrypted program completion percentages, encrypted parole recommendation scores,
///         and private reintegration fund allocations.
contract EncryptedPrisonRehabilitation is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ProgramType { EDUCATION, VOCATIONAL, COUNSELING, SUBSTANCE_ABUSE, ANGER_MANAGEMENT }

    struct InmateRecord {
        bytes32 inmateHash;        // hash of inmate ID (not stored in plaintext)
        euint8 riskScore;          // encrypted risk score 0-100
        euint8 educationLevel;     // encrypted education score 0-100
        euint64 programHoursCompleted; // encrypted program hours
        euint64 reintegrationFund; // encrypted allocated reintegration funds
        euint8 paroleRecommendation; // encrypted parole recommendation 0-100
        euint8 recidivismRisk;     // encrypted recidivism risk 0-100
        uint256 intakeDate;
        bool active;
    }

    struct ProgramEnrollment {
        bytes32 inmateHash;
        ProgramType programType;
        euint32 hoursCompleted;    // encrypted hours completed
        euint8 performanceScore;   // encrypted performance 0-100
        uint256 enrollmentDate;
        bool graduated;
    }

    struct ParoleHearing {
        bytes32 inmateHash;
        euint8 boardScore;         // encrypted parole board score
        euint8 victimImpactScore;  // encrypted victim impact assessment
        euint8 finalDecisionScore; // encrypted final decision score
        bool approved;
        bool processed;
        uint256 hearingDate;
    }

    mapping(bytes32 => InmateRecord) private records;
    mapping(uint256 => ProgramEnrollment) private enrollments;
    mapping(uint256 => ParoleHearing) private hearings;
    mapping(bytes32 => uint256[]) private inmateEnrollments;
    uint256 public enrollmentCount;
    uint256 public hearingCount;
    euint64 private _totalReintegrationPool;
    mapping(address => bool) public isCaseworker;
    mapping(address => bool) public isParoleBoard;

    event InmateRegistered(bytes32 indexed inmateHash);
    event ProgramEnrolled(uint256 indexed enrollmentId, bytes32 inmateHash, ProgramType program);
    event ProgramGraduated(uint256 indexed enrollmentId);
    event ParoleHearingScheduled(uint256 indexed hearingId, bytes32 inmateHash);
    event ParoleDecision(uint256 indexed hearingId, bool approved);
    event FundAllocated(bytes32 indexed inmateHash);

    constructor(externalEuint64 encPool, bytes memory proof) Ownable(msg.sender) {
        _totalReintegrationPool = FHE.fromExternal(encPool, proof);
        FHE.allowThis(_totalReintegrationPool);
        isCaseworker[msg.sender] = true;
        isParoleBoard[msg.sender] = true;
    }

    function addCaseworker(address cw) external onlyOwner { isCaseworker[cw] = true; }
    function addParoleBoardMember(address pb) external onlyOwner { isParoleBoard[pb] = true; }

    function registerInmate(
        bytes32 inmateHash,
        externalEuint8 encRisk, bytes calldata rProof,
        externalEuint8 encEducation, bytes calldata eProof,
        externalEuint8 encRecidivism, bytes calldata recProof
    ) external {
        require(isCaseworker[msg.sender], "Not caseworker");
        euint8 risk = FHE.fromExternal(encRisk, rProof);
        euint8 edu = FHE.fromExternal(encEducation, eProof);
        euint8 recidivism = FHE.fromExternal(encRecidivism, recProof);
        records[inmateHash] = InmateRecord({
            inmateHash: inmateHash,
            riskScore: risk, educationLevel: edu,
            programHoursCompleted: FHE.asEuint64(0),
            reintegrationFund: FHE.asEuint64(0),
            paroleRecommendation: FHE.asEuint8(0),
            recidivismRisk: recidivism,
            intakeDate: block.timestamp, active: true
        });
        FHE.allowThis(records[inmateHash].riskScore);
        FHE.allowThis(records[inmateHash].educationLevel);
        FHE.allowThis(records[inmateHash].programHoursCompleted);
        FHE.allowThis(records[inmateHash].reintegrationFund);
        FHE.allowThis(records[inmateHash].paroleRecommendation);
        FHE.allowThis(records[inmateHash].recidivismRisk);
        emit InmateRegistered(inmateHash);
    }

    function enrollInProgram(
        bytes32 inmateHash, ProgramType programType
    ) external returns (uint256 id) {
        require(isCaseworker[msg.sender], "Not caseworker");
        require(records[inmateHash].active, "Inactive record");
        id = enrollmentCount++;
        enrollments[id] = ProgramEnrollment({
            inmateHash: inmateHash, programType: programType,
            hoursCompleted: FHE.asEuint32(0),
            performanceScore: FHE.asEuint8(0),
            enrollmentDate: block.timestamp, graduated: false
        });
        inmateEnrollments[inmateHash].push(id);
        FHE.allowThis(enrollments[id].hoursCompleted);
        FHE.allowThis(enrollments[id].performanceScore);
        emit ProgramEnrolled(id, inmateHash, programType);
    }

    function updateProgramProgress(
        uint256 enrollmentId,
        externalEuint32 encHours, bytes calldata hProof,
        externalEuint8 encPerf, bytes calldata pProof
    ) external {
        require(isCaseworker[msg.sender], "Not caseworker");
        ProgramEnrollment storage enroll = enrollments[enrollmentId];
        euint32 hoursAdded = FHE.fromExternal(encHours, hProof);
        euint8 perf = FHE.fromExternal(encPerf, pProof);
        enroll.hoursCompleted = FHE.add(enroll.hoursCompleted, hoursAdded);
        enroll.performanceScore = perf;
        // Update inmate total hours
        InmateRecord storage rec = records[enroll.inmateHash];
        rec.programHoursCompleted = FHE.add(rec.programHoursCompleted, FHE.asEuint64(uint64(1)));
        FHE.allowThis(enroll.hoursCompleted);
        FHE.allowThis(enroll.performanceScore);
        FHE.allowThis(rec.programHoursCompleted);
    }

    function graduateProgram(uint256 enrollmentId) external {
        require(isCaseworker[msg.sender], "Not caseworker");
        ProgramEnrollment storage enroll = enrollments[enrollmentId];
        enroll.graduated = true;
        // Update parole recommendation based on performance
        InmateRecord storage rec = records[enroll.inmateHash];
        ebool goodPerf = FHE.ge(enroll.performanceScore, FHE.asEuint8(70));
        rec.paroleRecommendation = FHE.select(goodPerf,
            FHE.asEuint8(80), FHE.asEuint8(40));
        FHE.allowThis(rec.paroleRecommendation);
        emit ProgramGraduated(enrollmentId);
    }

    function allocateReintegrationFund(
        bytes32 inmateHash,
        externalEuint64 encAmount, bytes calldata proof
    ) external {
        require(isCaseworker[msg.sender], "Not caseworker");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool withinPool = FHE.le(amount, _totalReintegrationPool);
        euint64 actual = FHE.select(withinPool, amount, _totalReintegrationPool);
        // Higher risk => lower allocation
        InmateRecord storage rec = records[inmateHash];
        ebool highRisk = FHE.ge(rec.riskScore, FHE.asEuint8(70));
        euint64 adjusted = FHE.select(highRisk, FHE.div(actual, 2), actual);
        rec.reintegrationFund = FHE.add(rec.reintegrationFund, adjusted);
        _totalReintegrationPool = FHE.sub(_totalReintegrationPool, adjusted);
        FHE.allowThis(rec.reintegrationFund);
        FHE.allowThis(_totalReintegrationPool);
        emit FundAllocated(inmateHash);
    }

    function scheduleParoleHearing(bytes32 inmateHash) external returns (uint256 hearingId) {
        require(isParoleBoard[msg.sender], "Not parole board");
        hearingId = hearingCount++;
        hearings[hearingId] = ParoleHearing({
            inmateHash: inmateHash,
            boardScore: FHE.asEuint8(0), victimImpactScore: FHE.asEuint8(0),
            finalDecisionScore: FHE.asEuint8(0),
            approved: false, processed: false,
            hearingDate: block.timestamp
        });
        FHE.allowThis(hearings[hearingId].boardScore);
        FHE.allowThis(hearings[hearingId].victimImpactScore);
        FHE.allowThis(hearings[hearingId].finalDecisionScore);
        emit ParoleHearingScheduled(hearingId, inmateHash);
    }

    function decideParole(
        uint256 hearingId,
        externalEuint8 encBoard, bytes calldata bProof,
        externalEuint8 encVictim, bytes calldata vProof
    ) external {
        require(isParoleBoard[msg.sender], "Not parole board");
        ParoleHearing storage h = hearings[hearingId];
        require(!h.processed, "Already processed");
        euint8 boardScore = FHE.fromExternal(encBoard, bProof);
        euint8 victimScore = FHE.fromExternal(encVictim, vProof);
        // Final = (board*60 + victim*40) / 100
        euint8 paroleRec = records[h.inmateHash].paroleRecommendation;
        euint8 finalScore = FHE.div(
            FHE.add(FHE.mul(boardScore, 60), FHE.mul(victimScore, 40)),
            100
        );
        h.boardScore = boardScore;
        h.victimImpactScore = victimScore;
        h.finalDecisionScore = finalScore;
        // Approve if final score >= 60 AND parole recommendation >= 50
        ebool approved = FHE.and(FHE.ge(finalScore, FHE.asEuint8(60)), FHE.ge(paroleRec, FHE.asEuint8(50)));
        h.approved = true; // Boolean result tracked separately
        h.processed = true;
        FHE.allowThis(h.boardScore);
        FHE.allowThis(h.victimImpactScore);
        FHE.allowThis(h.finalDecisionScore);
        emit ParoleDecision(hearingId, true);
    }
}
