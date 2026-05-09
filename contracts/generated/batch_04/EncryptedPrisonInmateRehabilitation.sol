// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrisonInmateRehabilitation
/// @notice Criminal justice system for tracking inmate rehabilitation progress
///         with encrypted recidivism risk scores, program participation weights,
///         and parole board recommendations — protecting inmate dignity and privacy.
contract EncryptedPrisonInmateRehabilitation is
    ZamaEthereumConfig,
    Ownable,
    ReentrancyGuard
{
    enum ProgramType {
        EDUCATION,
        VOCATIONAL,
        THERAPY,
        RELIGIOUS,
        SUBSTANCE_ABUSE,
        ANGER_MANAGEMENT
    }
    enum ParoleDecision {
        PENDING,
        GRANTED,
        DEFERRED,
        DENIED
    }

    struct InmateRecord {
        euint16 anonymizedInmateId; // encrypted inmate ID
        euint8 riskScore; // encrypted ORAS/LSI-R recidivism risk 0-100
        euint8 programParticipation; // encrypted % participation
        euint8 behaviorScore; // encrypted conduct score 0-100
        euint8 educationProgress; // encrypted GED/literacy progress
        euint8 employabilityScore; // encrypted vocational readiness
        euint32 daysServed; // encrypted
        euint32 goodTimeCredits; // encrypted earned time off
        uint256 admissionDate;
        bool paroleEligible;
    }

    struct RehabProgram {
        string programName;
        ProgramType pType;
        euint8 completionRate; // encrypted % of enrolled who complete
        euint32 enrolledCount; // encrypted participants
        euint64 programCostUSD; // encrypted annual budget
        euint8 recidivismReductionBps; // encrypted effectiveness (bps)
        bool active;
    }

    struct ParoleHearing {
        uint256 inmateId;
        euint8 boardRiskScore; // encrypted re-assessment
        euint8 communitySupport; // encrypted support network score
        euint64 victimRestitutionPaid; // encrypted
        euint32 votesGranted; // encrypted parole board votes for
        euint32 votesAgainst; // encrypted votes against
        ParoleDecision decision;
        uint256 hearingDate;
    }

    mapping(uint256 => InmateRecord) private inmates;
    mapping(uint256 => RehabProgram) private programs;
    mapping(uint256 => ParoleHearing) private hearings;
    mapping(uint256 => mapping(uint256 => bool)) private inmatePrograms;
    mapping(address => bool) public isCorrectionOfficer;
    mapping(address => bool) public isParoleBoardMember;
    uint256 public inmateCount;
    uint256 public programCount;
    uint256 public hearingCount;
    euint32 private _totalGoodTimeGranted;
    euint64 private _totalRehabBudget;

    event InmateAdmitted(uint256 indexed inmateId);
    event ProgramEnrolled(uint256 indexed inmateId, uint256 programId);
    event ParoleHearingScheduled(uint256 indexed hearingId, uint256 inmateId);
    event ParoleDecisionMade(
        uint256 indexed hearingId,
        ParoleDecision decision
    );
    event RiskScoreUpdated(uint256 indexed inmateId);

    constructor() Ownable(msg.sender) {
        _totalGoodTimeGranted = FHE.asEuint32(0);
        _totalRehabBudget = FHE.asEuint64(0);
        FHE.allowThis(_totalGoodTimeGranted);
        FHE.allowThis(_totalRehabBudget);
        isCorrectionOfficer[msg.sender] = true;
        isParoleBoardMember[msg.sender] = true;
    }

    function addOfficer(address officer) external onlyOwner {
        isCorrectionOfficer[officer] = true;
    }
    function addBoardMember(address member) external onlyOwner {
        isParoleBoardMember[member] = true;
    }

    function admitInmate(
        externalEuint8 encRisk,
        bytes calldata rProof,
        externalEuint8 encBehavior,
        bytes calldata bProof,
        uint256 admissionDate
    ) external returns (uint256 inmateId) {
        require(isCorrectionOfficer[msg.sender], "Not officer");
        euint8 risk = FHE.fromExternal(encRisk, rProof);
        euint8 behavior = FHE.fromExternal(encBehavior, bProof);
        inmateId = inmateCount++;
        inmates[inmateId].anonymizedInmateId = FHE.asEuint16(uint16(inmateId + 50000));
        inmates[inmateId].riskScore = risk;
        inmates[inmateId].programParticipation = FHE.asEuint8(0);
        inmates[inmateId].behaviorScore = behavior;
        inmates[inmateId].educationProgress = FHE.asEuint8(0);
        inmates[inmateId].employabilityScore = FHE.asEuint8(0);
        inmates[inmateId].daysServed = FHE.asEuint32(0);
        inmates[inmateId].goodTimeCredits = FHE.asEuint32(0);
        inmates[inmateId].admissionDate = admissionDate;
        inmates[inmateId].paroleEligible = false;
        FHE.allowThis(inmates[inmateId].riskScore);
        FHE.allowThis(inmates[inmateId].programParticipation);
        FHE.allowThis(inmates[inmateId].behaviorScore);
        FHE.allowThis(inmates[inmateId].educationProgress);
        FHE.allowThis(inmates[inmateId].employabilityScore);
        FHE.allowThis(inmates[inmateId].daysServed);
        FHE.allowThis(inmates[inmateId].goodTimeCredits);
        FHE.allowThis(inmates[inmateId].anonymizedInmateId);
        emit InmateAdmitted(inmateId);
    }

    function createProgram(
        string calldata name,
        ProgramType pType,
        externalEuint64 encBudget,
        bytes calldata bProof,
        externalEuint8 encEffective,
        bytes calldata eProof
    ) external returns (uint256 progId) {
        require(isCorrectionOfficer[msg.sender], "Not officer");
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        euint8 effect = FHE.fromExternal(encEffective, eProof);
        progId = programCount++;
        programs[progId] = RehabProgram({
            programName: name,
            pType: pType,
            completionRate: FHE.asEuint8(0),
            enrolledCount: FHE.asEuint32(0),
            programCostUSD: budget,
            recidivismReductionBps: effect,
            active: true
        });
        _totalRehabBudget = FHE.add(_totalRehabBudget, budget);
        FHE.allowThis(programs[progId].completionRate);
        FHE.allowThis(programs[progId].enrolledCount);
        FHE.allowThis(programs[progId].programCostUSD);
        FHE.allowThis(programs[progId].recidivismReductionBps);
        FHE.allowThis(_totalRehabBudget);
    }

    function enrollInProgram(uint256 inmateId, uint256 programId) external {
        require(isCorrectionOfficer[msg.sender], "Not officer");
        require(!inmatePrograms[inmateId][programId], "Already enrolled");
        inmatePrograms[inmateId][programId] = true;
        programs[programId].enrolledCount = FHE.add(
            programs[programId].enrolledCount,
            FHE.asEuint32(1)
        );
        inmates[inmateId].programParticipation = FHE.add(
            inmates[inmateId].programParticipation,
            FHE.asEuint8(1)
        );
        FHE.allowThis(programs[programId].enrolledCount);
        FHE.allowThis(inmates[inmateId].programParticipation);
        emit ProgramEnrolled(inmateId, programId);
    }

    function updateRiskScore(
        uint256 inmateId,
        externalEuint8 encRisk,
        bytes calldata proof
    ) external {
        require(isParoleBoardMember[msg.sender], "Not board member");
        inmates[inmateId].riskScore = FHE.fromExternal(encRisk, proof);
        FHE.allowThis(inmates[inmateId].riskScore);
        emit RiskScoreUpdated(inmateId);
    }

    function awardGoodTimeCredits(
        uint256 inmateId,
        externalEuint32 encDays,
        bytes calldata proof
    ) external {
        require(isCorrectionOfficer[msg.sender], "Not officer");
        euint32 _days = FHE.fromExternal(encDays, proof);
        inmates[inmateId].goodTimeCredits = FHE.add(
            inmates[inmateId].goodTimeCredits,
            _days
        );
        _totalGoodTimeGranted = FHE.add(_totalGoodTimeGranted, _days);
        FHE.allowThis(inmates[inmateId].goodTimeCredits);
        FHE.allowThis(_totalGoodTimeGranted);
    }

    function scheduleParoleHearing(
        uint256 inmateId,
        externalEuint64 encRestitution,
        bytes calldata rProof
    ) external returns (uint256 hearingId) {
        require(isParoleBoardMember[msg.sender], "Not board member");
        euint64 restitution = FHE.fromExternal(encRestitution, rProof);
        hearingId = hearingCount++;
        hearings[hearingId] = ParoleHearing({
            inmateId: inmateId,
            boardRiskScore: inmates[inmateId].riskScore,
            communitySupport: FHE.asEuint8(0),
            victimRestitutionPaid: restitution,
            votesGranted: FHE.asEuint32(0),
            votesAgainst: FHE.asEuint32(0),
            decision: ParoleDecision.PENDING,
            hearingDate: block.timestamp + 30 days
        });
        FHE.allowThis(hearings[hearingId].boardRiskScore);
        FHE.allowThis(hearings[hearingId].communitySupport);
        FHE.allowThis(hearings[hearingId].victimRestitutionPaid);
        FHE.allowThis(hearings[hearingId].votesGranted);
        FHE.allowThis(hearings[hearingId].votesAgainst);
        emit ParoleHearingScheduled(hearingId, inmateId);
    }

    function castParoleVote(uint256 hearingId, bool voteGrant) external {
        require(isParoleBoardMember[msg.sender], "Not board member");
        if (voteGrant) {
            hearings[hearingId].votesGranted = FHE.add(
                hearings[hearingId].votesGranted,
                FHE.asEuint32(1)
            );
            FHE.allowThis(hearings[hearingId].votesGranted);
        } else {
            hearings[hearingId].votesAgainst = FHE.add(
                hearings[hearingId].votesAgainst,
                FHE.asEuint32(1)
            );
            FHE.allowThis(hearings[hearingId].votesAgainst);
        }
    }

    function finalizeParoleDecision(
        uint256 hearingId,
        ParoleDecision decision
    ) external {
        require(isParoleBoardMember[msg.sender], "Not board member");
        hearings[hearingId].decision = decision;
        if (decision == ParoleDecision.GRANTED) {
            inmates[hearings[hearingId].inmateId].paroleEligible = true;
        }
        emit ParoleDecisionMade(hearingId, decision);
    }

    function allowRehabView(address viewer) external onlyOwner {
        FHE.allow(_totalGoodTimeGranted, viewer);
        FHE.allow(_totalRehabBudget, viewer);
    }
}
