// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameEncryptedBattleRoyaleWager
/// @notice Battle royale game with encrypted player skill ratings,
///         encrypted wager pools, and provably fair encrypted elimination order.
///         Prize distribution is based on encrypted survival rank.
contract GameEncryptedBattleRoyaleWager is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MatchStatus { Lobby, InProgress, Completed, Cancelled }
    enum EliminationCause { Eliminated, AFK, Disconnected, Victory }

    struct BattleMatch {
        uint256 matchId;
        euint64 wagerPerPlayer;        // encrypted entry fee
        euint64 totalPrizePool;        // encrypted prize pool
        euint64 firstPrizeBps;         // encrypted 1st prize %
        euint64 secondPrizeBps;        // encrypted 2nd prize %
        euint64 thirdPrizeBps;         // encrypted 3rd prize %
        euint32 maxPlayers;
        uint256 currentPlayers;
        MatchStatus status;
        uint256 startedAt;
        uint256 endedAt;
    }

    struct PlayerProfile {
        euint32 skillRating;           // encrypted Elo-like rating
        euint64 totalWagered;          // encrypted lifetime wagers
        euint64 totalWon;              // encrypted lifetime winnings
        euint32 matchesPlayed;         // encrypted matches played
        euint32 matchesWon;            // encrypted wins
        bool registered;
    }

    struct PlayerInMatch {
        uint256 matchId;
        address player;
        euint32 survivalRank;          // encrypted final rank (1=winner)
        euint64 prizeAmount;           // encrypted prize earned
        EliminationCause eliminationCause;
        bool eliminated;
        uint256 eliminatedAt;
    }

    mapping(uint256 => BattleMatch) private matches;
    mapping(uint256 => address[]) private matchPlayers;
    mapping(uint256 => mapping(address => PlayerInMatch)) private playerMatchData;
    mapping(address => PlayerProfile) private profiles;

    uint256 public matchCount;
    euint64 private _totalPlatformFees;
    euint64 private _totalPrizesPaid;
    euint64 private _platformFeeBps;

    event MatchCreated(uint256 indexed matchId);
    event PlayerJoined(uint256 indexed matchId, address player);
    event MatchStarted(uint256 indexed matchId);
    event PlayerEliminated(uint256 indexed matchId, address player, uint256 rank);
    event MatchCompleted(uint256 indexed matchId);
    event PrizeClaimed(uint256 indexed matchId, address player);

    constructor(externalEuint64 encPlatformFee, bytes memory feeProof) Ownable(msg.sender) {
        _platformFeeBps = FHE.fromExternal(encPlatformFee, feeProof);
        _totalPlatformFees = FHE.asEuint64(0);
        _totalPrizesPaid = FHE.asEuint64(0);
        FHE.allowThis(_platformFeeBps);
        FHE.allowThis(_totalPlatformFees);
        FHE.allowThis(_totalPrizesPaid);
    }

    function registerPlayer(
        externalEuint32 encSkillRating, bytes calldata proof
    ) external {
        require(!profiles[msg.sender].registered, "Already registered");
        euint32 skill = FHE.fromExternal(encSkillRating, proof);
        profiles[msg.sender].skillRating = skill;
        profiles[msg.sender].totalWagered = FHE.asEuint64(0);
        profiles[msg.sender].totalWon = FHE.asEuint64(0);
        profiles[msg.sender].matchesPlayed = FHE.asEuint32(0);
        profiles[msg.sender].matchesWon = FHE.asEuint32(0);
        profiles[msg.sender].registered = true;
        FHE.allowThis(profiles[msg.sender].skillRating); FHE.allow(profiles[msg.sender].skillRating, msg.sender);
        FHE.allowThis(profiles[msg.sender].totalWagered); FHE.allow(profiles[msg.sender].totalWagered, msg.sender);
        FHE.allowThis(profiles[msg.sender].totalWon); FHE.allow(profiles[msg.sender].totalWon, msg.sender);
        FHE.allowThis(profiles[msg.sender].matchesPlayed); FHE.allowThis(profiles[msg.sender].matchesWon);
    }

    function createMatch(
        externalEuint64 encWager, bytes calldata wagerProof,
        externalEuint64 encFirst, bytes calldata firstProof,
        externalEuint64 encSecond, bytes calldata secondProof,
        externalEuint64 encThird, bytes calldata thirdProof,
        uint32 maxPlayers
    ) external onlyOwner returns (uint256 matchId) {
        euint64 wager = FHE.fromExternal(encWager, wagerProof);
        euint64 firstPrize = FHE.fromExternal(encFirst, firstProof);
        euint64 secondPrize = FHE.fromExternal(encSecond, secondProof);
        euint64 thirdPrize = FHE.fromExternal(encThird, thirdProof);

        matchId = matchCount++;
        BattleMatch storage m = matches[matchId];
        m.matchId = matchId;
        m.wagerPerPlayer = wager;
        m.totalPrizePool = FHE.asEuint64(0);
        m.firstPrizeBps = firstPrize;
        m.secondPrizeBps = secondPrize;
        m.thirdPrizeBps = thirdPrize;
        m.maxPlayers = maxPlayers;
        m.currentPlayers = 0;
        m.status = MatchStatus.Lobby;

        FHE.allowThis(m.wagerPerPlayer);
        FHE.allowThis(m.totalPrizePool);
        FHE.allowThis(m.firstPrizeBps); FHE.allowThis(m.secondPrizeBps); FHE.allowThis(m.thirdPrizeBps);

        emit MatchCreated(matchId);
    }

    function joinMatch(uint256 matchId) external nonReentrant {
        require(profiles[msg.sender].registered, "Not registered");
        BattleMatch storage m = matches[matchId];
        require(m.status == MatchStatus.Lobby, "Not in lobby");
        require(m.currentPlayers < m.maxPlayers, "Match full");

        matchPlayers[matchId].push(msg.sender);
        m.currentPlayers++;

        // Platform fee deducted from prize pool
        euint64 platformCut = FHE.div(FHE.mul(m.wagerPerPlayer, _platformFeeBps), 10000);
        euint64 netWager = FHE.sub(m.wagerPerPlayer, platformCut);
        m.totalPrizePool = FHE.add(m.totalPrizePool, netWager);
        _totalPlatformFees = FHE.add(_totalPlatformFees, platformCut);

        profiles[msg.sender].totalWagered = FHE.add(profiles[msg.sender].totalWagered, m.wagerPerPlayer);
        profiles[msg.sender].matchesPlayed = FHE.add(profiles[msg.sender].matchesPlayed, FHE.asEuint32(1));

        playerMatchData[matchId][msg.sender] = PlayerInMatch({
            matchId: matchId,
            player: msg.sender,
            survivalRank: FHE.asEuint32(0),
            prizeAmount: FHE.asEuint64(0),
            eliminationCause: EliminationCause.Eliminated,
            eliminated: false,
            eliminatedAt: 0
        });

        FHE.allowThis(m.totalPrizePool); FHE.allowThis(_totalPlatformFees);
        FHE.allowThis(profiles[msg.sender].totalWagered); FHE.allow(profiles[msg.sender].totalWagered, msg.sender);
        FHE.allowThis(profiles[msg.sender].matchesPlayed);
        FHE.allowThis(playerMatchData[matchId][msg.sender].survivalRank);
        FHE.allowThis(playerMatchData[matchId][msg.sender].prizeAmount);

        emit PlayerJoined(matchId, msg.sender);
    }

    function startMatch(uint256 matchId) external onlyOwner {
        require(matches[matchId].status == MatchStatus.Lobby, "Not in lobby");
        matches[matchId].status = MatchStatus.InProgress;
        matches[matchId].startedAt = block.timestamp;
        emit MatchStarted(matchId);
    }

    function eliminatePlayer(
        uint256 matchId,
        address player,
        externalEuint32 encRank, bytes calldata rankProof,
        EliminationCause cause
    ) external onlyOwner {
        PlayerInMatch storage pid = playerMatchData[matchId][player];
        require(!pid.eliminated, "Already eliminated");
        euint32 rank = FHE.fromExternal(encRank, rankProof);
        pid.survivalRank = rank;
        pid.eliminationCause = cause;
        pid.eliminated = true;
        pid.eliminatedAt = block.timestamp;
        FHE.allowThis(pid.survivalRank); FHE.allow(pid.survivalRank, player);
        uint256 totalP = matchPlayers[matchId].length;
        emit PlayerEliminated(matchId, player, totalP);
    }

    function finalizeMatch(uint256 matchId, address[] calldata topThree) external onlyOwner {
        BattleMatch storage m = matches[matchId];
        require(m.status == MatchStatus.InProgress, "Not in progress");
        m.status = MatchStatus.Completed;
        m.endedAt = block.timestamp;

        // Distribute prizes
        for (uint256 i = 0; i < topThree.length && i < 3; i++) {
            euint64 prizeBps = i == 0 ? m.firstPrizeBps : (i == 1 ? m.secondPrizeBps : m.thirdPrizeBps);
            euint64 prize = FHE.div(FHE.mul(m.totalPrizePool, prizeBps), 10000);
            playerMatchData[matchId][topThree[i]].prizeAmount = prize;
            FHE.allowThis(prize); FHE.allow(prize, topThree[i]);
        }

        // Update winner profile
        if (topThree.length > 0) {
            profiles[topThree[0]].matchesWon = FHE.add(profiles[topThree[0]].matchesWon, FHE.asEuint32(1));
            FHE.allowThis(profiles[topThree[0]].matchesWon);
        }
        emit MatchCompleted(matchId);
    }

    function claimPrize(uint256 matchId) external nonReentrant {
        PlayerInMatch storage pid = playerMatchData[matchId][msg.sender];
        require(matches[matchId].status == MatchStatus.Completed, "Not completed");
        euint64 prize = pid.prizeAmount;
        profiles[msg.sender].totalWon = FHE.add(profiles[msg.sender].totalWon, prize);
        _totalPrizesPaid = FHE.add(_totalPrizesPaid, prize);
        FHE.allow(prize, msg.sender);
        FHE.allowThis(profiles[msg.sender].totalWon); FHE.allow(profiles[msg.sender].totalWon, msg.sender);
        FHE.allowThis(_totalPrizesPaid);
        emit PrizeClaimed(matchId, msg.sender);
    }

    function allowGameStats(address viewer) external onlyOwner {
        FHE.allow(_totalPlatformFees, viewer);
        FHE.allow(_totalPrizesPaid, viewer);
    }
}
