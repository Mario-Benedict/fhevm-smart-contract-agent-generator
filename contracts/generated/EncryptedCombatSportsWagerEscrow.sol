// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCombatSportsWagerEscrow
/// @notice Professional combat sports betting escrow where wager amounts,
///         odds, and fighter performance statistics remain encrypted.
///         Supports boxing, MMA, kickboxing events with private P2P wagering.
contract EncryptedCombatSportsWagerEscrow is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FightDiscipline { BOXING, MMA, MUAY_THAI, KICKBOXING, WRESTLING, JUDO }
    enum FightOutcome { PENDING, FIGHTER_A_WIN, FIGHTER_B_WIN, DRAW, NO_CONTEST, TKO_A, TKO_B }
    enum WinMethod { DECISION, KO, TKO, SUBMISSION, DQ, SPLIT_DECISION }

    struct FighterProfile {
        string fighterName;
        string nationality;
        euint8  weightClassKg;         // encrypted weight class
        euint16 professionalRecord;    // encrypted W-L-D packed
        euint32 eloRating;             // encrypted Elo performance rating
        euint8  injuryRiskScore;       // encrypted 0-100 risk
        euint64 careerEarningsUSD;     // encrypted career prize money
        bool active;
    }

    struct FightEvent {
        string eventName;
        string venue;
        FightDiscipline discipline;
        uint256 fighterId_A;
        uint256 fighterId_B;
        euint64 oddsA;                 // encrypted fighter A odds (scaled 1e4)
        euint64 oddsB;                 // encrypted fighter B odds
        euint64 totalEscrowedA;        // encrypted total backing fighter A
        euint64 totalEscrowedB;        // encrypted total backing fighter B
        euint32 scheduledRounds;
        uint256 eventDate;
        FightOutcome outcome;
        WinMethod winMethod;
        bool resolved;
    }

    struct WagerPosition {
        uint256 eventId;
        euint64 wagerAmount;           // encrypted stake
        euint64 potentialPayout;       // encrypted payout if win
        bool backingFighterA;
        bool settled;
        bool claimed;
    }

    mapping(uint256 => FighterProfile) private fighters;
    mapping(uint256 => FightEvent) private events;
    mapping(bytes32 => WagerPosition) private wagers; // keccak256(bettor, eventId)
    mapping(address => bool) public isOracle;
    mapping(address => bool) public isEventOrganizer;
    uint256 public fighterCount;
    uint256 public eventCount;
    euint64 private _houseTotalCommission;
    euint64 private _totalVolumeWagered;
    euint16 private _houseCommissionBps;

    event FighterRegistered(uint256 indexed fighterId, string name);
    event EventCreated(uint256 indexed eventId, string name);
    event WagerPlaced(uint256 indexed eventId, address indexed bettor);
    event EventResolved(uint256 indexed eventId, FightOutcome outcome);
    event WinningsSettled(uint256 indexed eventId, address indexed bettor);

    constructor(uint16 commissionBps) Ownable(msg.sender) {
        _houseTotalCommission = FHE.asEuint64(0);
        _totalVolumeWagered = FHE.asEuint64(0);
        _houseCommissionBps = FHE.asEuint16(commissionBps);
        FHE.allowThis(_houseTotalCommission);
        FHE.allowThis(_totalVolumeWagered);
        FHE.allowThis(_houseCommissionBps);
        isOracle[msg.sender] = true;
        isEventOrganizer[msg.sender] = true;
    }

    function addOracle(address oracle) external onlyOwner { isOracle[oracle] = true; }
    function addOrganizer(address org) external onlyOwner { isEventOrganizer[org] = true; }

    function registerFighter(
        string calldata name,
        string calldata nationality,
        externalEuint8  encWeightClass, bytes calldata wcProof,
        externalEuint32 encElo,         bytes calldata eloProof,
        externalEuint8  encInjuryRisk,  bytes calldata irProof
    ) external returns (uint256 fighterId) {
        require(isEventOrganizer[msg.sender], "Not organizer");
        euint8  weight = FHE.fromExternal(encWeightClass, wcProof);
        euint32 elo    = FHE.fromExternal(encElo, eloProof);
        euint8  injury = FHE.fromExternal(encInjuryRisk, irProof);
        fighterId = fighterCount++;
        fighters[fighterId] = FighterProfile({
            fighterName: name,
            nationality: nationality,
            weightClassKg: weight,
            professionalRecord: FHE.asEuint16(0),
            eloRating: elo,
            injuryRiskScore: injury,
            careerEarningsUSD: FHE.asEuint64(0),
            active: true
        });
        FHE.allowThis(fighters[fighterId].weightClassKg);
        FHE.allowThis(fighters[fighterId].eloRating);
        FHE.allowThis(fighters[fighterId].injuryRiskScore);
        FHE.allowThis(fighters[fighterId].careerEarningsUSD);
        FHE.allowThis(fighters[fighterId].professionalRecord);
        emit FighterRegistered(fighterId, name);
    }

    function createEvent(
        string calldata eventName,
        string calldata venue,
        FightDiscipline discipline,
        uint256 fighterA,
        uint256 fighterB,
        externalEuint64 encOddsA, bytes calldata oaProof,
        externalEuint64 encOddsB, bytes calldata obProof,
        externalEuint32 encRounds, bytes calldata rProof,
        uint256 eventDate
    ) external returns (uint256 eventId) {
        require(isEventOrganizer[msg.sender], "Not organizer");
        euint64 oddsA = FHE.fromExternal(encOddsA, oaProof);
        euint64 oddsB = FHE.fromExternal(encOddsB, obProof);
        euint32 rounds = FHE.fromExternal(encRounds, rProof);
        eventId = eventCount++;
        events[eventId] = FightEvent({
            eventName: eventName,
            venue: venue,
            discipline: discipline,
            fighterId_A: fighterA,
            fighterId_B: fighterB,
            oddsA: oddsA,
            oddsB: oddsB,
            totalEscrowedA: FHE.asEuint64(0),
            totalEscrowedB: FHE.asEuint64(0),
            scheduledRounds: rounds,
            eventDate: eventDate,
            outcome: FightOutcome.PENDING,
            winMethod: WinMethod.DECISION,
            resolved: false
        });
        FHE.allowThis(events[eventId].oddsA);
        FHE.allowThis(events[eventId].oddsB);
        FHE.allowThis(events[eventId].totalEscrowedA);
        FHE.allowThis(events[eventId].totalEscrowedB);
        FHE.allowThis(events[eventId].scheduledRounds);
        emit EventCreated(eventId, eventName);
    }

    function placeWager(
        uint256 eventId,
        bool backingFighterA,
        externalEuint64 encWager, bytes calldata proof
    ) external nonReentrant {
        require(!events[eventId].resolved, "Event resolved");
        require(block.timestamp < events[eventId].eventDate, "Event started");
        euint64 wager = FHE.fromExternal(encWager, proof);
        // Calculate potential payout based on encrypted odds
        euint64 odds = backingFighterA ? events[eventId].oddsA : events[eventId].oddsB;
        euint64 payout = FHE.div(FHE.mul(wager, odds), 10000);
        bytes32 wagerId = keccak256(abi.encodePacked(msg.sender, eventId));
        wagers[wagerId] = WagerPosition({
            eventId: eventId,
            wagerAmount: wager,
            potentialPayout: payout,
            backingFighterA: backingFighterA,
            settled: false,
            claimed: false
        });
        if (backingFighterA) {
            events[eventId].totalEscrowedA = FHE.add(events[eventId].totalEscrowedA, wager);
            FHE.allowThis(events[eventId].totalEscrowedA);
        } else {
            events[eventId].totalEscrowedB = FHE.add(events[eventId].totalEscrowedB, wager);
            FHE.allowThis(events[eventId].totalEscrowedB);
        }
        _totalVolumeWagered = FHE.add(_totalVolumeWagered, wager);
        FHE.allowThis(wagers[wagerId].wagerAmount);
        FHE.allow(wagers[wagerId].wagerAmount, msg.sender);
        FHE.allowThis(wagers[wagerId].potentialPayout);
        FHE.allow(wagers[wagerId].potentialPayout, msg.sender);
        FHE.allowThis(_totalVolumeWagered);
        emit WagerPlaced(eventId, msg.sender);
    }

    function resolveEvent(
        uint256 eventId,
        FightOutcome outcome,
        WinMethod method
    ) external {
        require(isOracle[msg.sender], "Not oracle");
        require(!events[eventId].resolved, "Already resolved");
        events[eventId].outcome = outcome;
        events[eventId].winMethod = method;
        events[eventId].resolved = true;
        emit EventResolved(eventId, outcome);
    }

    function claimWinnings(uint256 eventId) external nonReentrant {
        require(events[eventId].resolved, "Not resolved");
        bytes32 wagerId = keccak256(abi.encodePacked(msg.sender, eventId));
        WagerPosition storage wager = wagers[wagerId];
        require(!wager.claimed, "Already claimed");
        FightOutcome outcome = events[eventId].outcome;
        bool won = (wager.backingFighterA && (outcome == FightOutcome.FIGHTER_A_WIN || outcome == FightOutcome.TKO_A)) ||
                   (!wager.backingFighterA && (outcome == FightOutcome.FIGHTER_B_WIN || outcome == FightOutcome.TKO_B));
        euint64 commission = FHE.div(FHE.mul(wager.wagerAmount, 200), 10000); // 2% commission
        _houseTotalCommission = FHE.add(_houseTotalCommission, commission);
        wager.claimed = true;
        wager.settled = true;
        // Update fighter earnings if applicable
        if (won && outcome != FightOutcome.DRAW) {
            uint256 winnerFighterId = (outcome == FightOutcome.FIGHTER_A_WIN || outcome == FightOutcome.TKO_A)
                ? events[eventId].fighterId_A : events[eventId].fighterId_B;
            fighters[winnerFighterId].careerEarningsUSD = FHE.add(
                fighters[winnerFighterId].careerEarningsUSD, wager.potentialPayout
            );
            FHE.allowThis(fighters[winnerFighterId].careerEarningsUSD);
        }
        FHE.allowThis(_houseTotalCommission);
        FHE.allow(wager.potentialPayout, msg.sender);
        emit WinningsSettled(eventId, msg.sender);
    }

    function allowVolumeView(address viewer) external onlyOwner {
        FHE.allow(_houseTotalCommission, viewer);
        FHE.allow(_totalVolumeWagered, viewer);
    }
}
