// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivatePrisonRehabilitation Funding
/// @notice Government-backed Social Impact Bond for prison rehab programs.
///         Encrypted recidivism rates, encrypted program costs, and outcome-based payments.
contract PrivatePrisonRehabilitationFunding is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ProgramType { VocationalTraining, MentalHealth, SubstanceAbuse, Education, EmploymentPlacement }
    enum OutcomeStatus { InProgress, MeasurementPending, Achieved, Missed, Disputed }

    struct SocialImpactBond {
        address serviceProvider;
        address outcomePayer;          // government agency
        ProgramType programType;
        string prisonFacilityId;
        euint32 participantCount;      // encrypted number of participants
        euint64 programCostUSD;        // encrypted total program cost
        euint64 maximumPayoutUSD;      // encrypted max government payout
        euint16 targetRecidivismBps;   // encrypted target recidivism rate
        euint16 baselineRecidivismBps; // encrypted baseline recidivism rate
        euint64 actualPayoutUSD;       // encrypted earned payout
        uint256 measurementDate;
        OutcomeStatus status;
    }

    struct OutcomeMeasurement {
        uint256 bondId;
        euint32 participantsFollowedUp; // encrypted follow-up count
        euint16 measuredRecidivismBps;  // encrypted actual recidivism
        euint64 earnedPayoutUSD;        // encrypted earned payout
        address measurer;
        uint256 measuredAt;
    }

    mapping(uint256 => SocialImpactBond) private bonds;
    mapping(uint256 => OutcomeMeasurement[]) private measurements;
    mapping(address => bool) public isOutcomeAuditor;

    uint256 public bondCount;
    euint64 private _totalCommitted;
    euint64 private _totalPaidOut;

    event BondIssued(uint256 indexed id, ProgramType pType, string facility);
    event OutcomeMeasured(uint256 indexed bondId, uint256 measurementIndex);
    event PaymentReleased(uint256 indexed bondId);

    modifier onlyAuditor() {
        require(isOutcomeAuditor[msg.sender] || msg.sender == owner(), "Not auditor");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCommitted = FHE.asEuint64(0);
        _totalPaidOut = FHE.asEuint64(0);
        FHE.allowThis(_totalCommitted);
        FHE.allowThis(_totalPaidOut);
        isOutcomeAuditor[msg.sender] = true;
    }

    function addAuditor(address a) external onlyOwner { isOutcomeAuditor[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function issueBond(
        address outcomePayer,
        ProgramType programType,
        string calldata facilityId,
        externalEuint32 encParticipants, bytes calldata pProof,
        externalEuint64 encCost, bytes calldata cProof,
        externalEuint64 encMaxPayout, bytes calldata mpProof,
        externalEuint16 encTargetRecidivism, bytes calldata trProof,
        externalEuint16 encBaselineRecidivism, bytes calldata brProof,
        uint256 measurementDays
    ) external whenNotPaused returns (uint256 id) {
        euint32 participants = FHE.fromExternal(encParticipants, pProof);
        euint64 cost = FHE.fromExternal(encCost, cProof);
        euint64 maxPayout = FHE.fromExternal(encMaxPayout, mpProof);
        euint16 targetRecid = FHE.fromExternal(encTargetRecidivism, trProof);
        euint16 baselineRecid = FHE.fromExternal(encBaselineRecidivism, brProof);
        id = bondCount++;
        bonds[id] = SocialImpactBond({
            serviceProvider: msg.sender, outcomePayer: outcomePayer,
            programType: programType, prisonFacilityId: facilityId,
            participantCount: participants, programCostUSD: cost,
            maximumPayoutUSD: maxPayout, targetRecidivismBps: targetRecid,
            baselineRecidivismBps: baselineRecid, actualPayoutUSD: FHE.asEuint64(0),
            measurementDate: block.timestamp + measurementDays * 1 days,
            status: OutcomeStatus.InProgress
        });
        _totalCommitted = FHE.add(_totalCommitted, maxPayout);
        FHE.allowThis(bonds[id].participantCount);
        FHE.allow(bonds[id].participantCount, msg.sender);
        FHE.allow(bonds[id].participantCount, outcomePayer);
        FHE.allowThis(bonds[id].programCostUSD);
        FHE.allow(bonds[id].programCostUSD, msg.sender);
        FHE.allowThis(bonds[id].maximumPayoutUSD);
        FHE.allow(bonds[id].maximumPayoutUSD, outcomePayer);
        FHE.allowThis(bonds[id].targetRecidivismBps);
        FHE.allowThis(bonds[id].baselineRecidivismBps);
        FHE.allowThis(bonds[id].actualPayoutUSD);
        FHE.allowThis(_totalCommitted);
        emit BondIssued(id, programType, facilityId);
    }

    function submitMeasurement(
        uint256 bondId,
        externalEuint32 encFollowedUp, bytes calldata fuProof,
        externalEuint16 encMeasuredRecid, bytes calldata mrProof
    ) external onlyAuditor returns (uint256 measureIndex) {
        SocialImpactBond storage b = bonds[bondId];
        require(block.timestamp >= b.measurementDate, "Too early");
        euint32 followedUp = FHE.fromExternal(encFollowedUp, fuProof);
        euint16 measured = FHE.fromExternal(encMeasuredRecid, mrProof);
        // Payout = maxPayout if measured < target, else 0
        ebool achieved = FHE.lt(measured, b.targetRecidivismBps);
        euint64 payout = FHE.select(achieved, b.maximumPayoutUSD, FHE.asEuint64(0));
        b.actualPayoutUSD = payout;
        b.status = FHE.isInitialized(achieved) ? OutcomeStatus.Achieved : OutcomeStatus.Missed;
        OutcomeMeasurement memory m = OutcomeMeasurement({
            bondId: bondId, participantsFollowedUp: followedUp,
            measuredRecidivismBps: measured, earnedPayoutUSD: payout,
            measurer: msg.sender, measuredAt: block.timestamp
        });
        measurements[bondId].push(m);
        measureIndex = measurements[bondId].length - 1;
        FHE.allowThis(b.actualPayoutUSD);
        FHE.allow(b.actualPayoutUSD, b.serviceProvider);
        FHE.allow(b.actualPayoutUSD, b.outcomePayer);
        FHE.allowThis(m.participantsFollowedUp);
        FHE.allowThis(m.measuredRecidivismBps);
        FHE.allowThis(m.earnedPayoutUSD);
        emit OutcomeMeasured(bondId, measureIndex);
    }

    function releasePayout(uint256 bondId) external onlyAuditor nonReentrant {
        SocialImpactBond storage b = bonds[bondId];
        require(b.status == OutcomeStatus.Achieved, "Outcome not achieved");
        _totalPaidOut = FHE.add(_totalPaidOut, b.actualPayoutUSD);
        FHE.allowThis(_totalPaidOut);
        emit PaymentReleased(bondId);
    }

    function allowProgramStats(address viewer) external onlyOwner {
        FHE.allow(_totalCommitted, viewer);
        FHE.allow(_totalPaidOut, viewer);
    }
}
