// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedEsportsTournamentStaking
/// @notice E-sports tournament with encrypted entry fees, prize pools, and
///         player performance ratings. Brackets are blind until reveal phase
///         to prevent strategic forfeiting.
contract EncryptedEsportsTournamentStaking is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {

    uint8 public constant MAX_PLAYERS = 64;

    enum TournamentPhase { Registration, Seeding, BracketPlay, Finals, Complete }

    struct Tournament {
        string game;
        TournamentPhase phase;
        euint64 prizePool;              // encrypted accumulated prize pool
        euint32 entryFeeEncrypted;      // encrypted entry fee in tokens
        uint8 registeredCount;
        uint256 registrationDeadline;
        address champion;
    }

    struct PlayerProfile {
        euint32 skillRating;            // encrypted ELO/rating
        euint32 tournamentWins;         // encrypted wins count
        euint64 totalEarnings;          // encrypted total prize earnings
        bool registered;
    }

    uint256 public nextTournamentId;
    mapping(uint256 => Tournament) private tournaments;
    mapping(uint256 => mapping(address => bool)) private entrants;
    mapping(uint256 => euint32) private roundMatchResults; // encrypted match outcomes
    mapping(address => PlayerProfile) private profiles;

    event TournamentCreated(uint256 indexed id, string game);
    event PlayerRegistered(uint256 indexed tournamentId, address player);
    event PhaseAdvanced(uint256 indexed tournamentId, TournamentPhase newPhase);
    event MatchResultRecorded(uint256 indexed tournamentId, uint256 matchId);
    event ChampionCrowned(uint256 indexed tournamentId, address champion);

    constructor() Ownable(msg.sender) {}

    function createTournament(
        string calldata game,
        externalEuint32 encEntryFee,
        bytes calldata feeProof,
        uint256 registrationDeadline
    ) external onlyOwner returns (uint256 id) {
        id = nextTournamentId++;
        euint32 fee = FHE.fromExternal(encEntryFee, feeProof);
        tournaments[id] = Tournament({
            game: game,
            phase: TournamentPhase.Registration,
            prizePool: FHE.asEuint64(0),
            entryFeeEncrypted: fee,
            registeredCount: 0,
            registrationDeadline: registrationDeadline,
            champion: address(0)
        });
        FHE.allowThis(tournaments[id].prizePool);
        FHE.allowThis(tournaments[id].entryFeeEncrypted);
        emit TournamentCreated(id, game);
    }

    function registerPlayer(uint256 tournamentId) external whenNotPaused {
        Tournament storage t = tournaments[tournamentId];
        require(t.phase == TournamentPhase.Registration, "Registration closed");
        require(block.timestamp < t.registrationDeadline, "Deadline passed");
        require(!entrants[tournamentId][msg.sender], "Already registered");
        require(t.registeredCount < MAX_PLAYERS, "Full");

        entrants[tournamentId][msg.sender] = true;
        t.registeredCount++;

        // Add entry fee to prize pool
        t.prizePool = FHE.add(t.prizePool, FHE.asEuint64(t.entryFeeEncrypted));
        FHE.allowThis(t.prizePool);

        // Initialize player profile if needed
        if (!profiles[msg.sender].registered) {
            profiles[msg.sender] = PlayerProfile({
                skillRating: FHE.asEuint32(1000),
                tournamentWins: FHE.asEuint32(0),
                totalEarnings: FHE.asEuint64(0),
                registered: true
            });
            FHE.allowThis(profiles[msg.sender].skillRating);
            FHE.allow(profiles[msg.sender].skillRating, msg.sender);
            FHE.allowThis(profiles[msg.sender].tournamentWins);
            FHE.allowThis(profiles[msg.sender].totalEarnings);
            FHE.allow(profiles[msg.sender].totalEarnings, msg.sender);
        }
        emit PlayerRegistered(tournamentId, msg.sender);
    }

    function advancePhase(uint256 tournamentId) external onlyOwner {
        Tournament storage t = tournaments[tournamentId];
        require(uint8(t.phase) < uint8(TournamentPhase.Complete), "Already complete");
        t.phase = TournamentPhase(uint8(t.phase) + 1);
        emit PhaseAdvanced(tournamentId, t.phase);
    }

    function recordMatchResult(
        uint256 tournamentId,
        uint256 matchId,
        address winner,
        address loser,
        externalEuint32 encWinnerRatingDelta,
        bytes calldata winnerProof,
        externalEuint32 encLoserRatingDelta,
        bytes calldata loserProof
    ) external onlyOwner {
        euint32 winnerDelta = FHE.fromExternal(encWinnerRatingDelta, winnerProof);
        euint32 loserDelta = FHE.fromExternal(encLoserRatingDelta, loserProof);

        profiles[winner].skillRating = FHE.add(profiles[winner].skillRating, winnerDelta);
        FHE.allowThis(profiles[winner].skillRating);
        FHE.allow(profiles[winner].skillRating, winner);

        // Loser rating decreases (ensure no underflow)
        ebool canDecrease = FHE.ge(profiles[loser].skillRating, loserDelta);
        profiles[loser].skillRating = FHE.select(
            canDecrease,
            ebool _safeSub221 = FHE.ge(profiles[loser].skillRating, loserDelta);
            FHE.select(_safeSub221, FHE.sub(profiles[loser].skillRating, loserDelta), FHE.asEuint64(0)),
            FHE.asEuint32(1)
        );
        FHE.allowThis(profiles[loser].skillRating);
        FHE.allow(profiles[loser].skillRating, loser);
        emit MatchResultRecorded(tournamentId, matchId);
    }

    function crownChampion(
        uint256 tournamentId,
        address champion
    ) external onlyOwner {
        Tournament storage t = tournaments[tournamentId];
        require(t.phase == TournamentPhase.Finals, "Not finals");
        t.champion = champion;
        t.phase = TournamentPhase.Complete;

        profiles[champion].tournamentWins = FHE.add(profiles[champion].tournamentWins, FHE.asEuint32(1));
        profiles[champion].totalEarnings = FHE.add(profiles[champion].totalEarnings, t.prizePool);
        FHE.allowThis(profiles[champion].tournamentWins);
        FHE.allowThis(profiles[champion].totalEarnings);
        FHE.allow(profiles[champion].totalEarnings, champion);
        FHE.allow(t.prizePool, champion);
        emit ChampionCrowned(tournamentId, champion);
    }

    function allowProfileView(address viewer) external {
        FHE.allow(profiles[msg.sender].skillRating, viewer);
        FHE.allow(profiles[msg.sender].totalEarnings, viewer);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
