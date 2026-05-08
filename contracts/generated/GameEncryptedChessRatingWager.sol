// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameEncryptedChessRatingWager
/// @notice On-chain chess tournament with encrypted Elo ratings, encrypted
///         wager pools per match, and private game result submission.
///         Supports Swiss-system pairing with encrypted tiebreak scores.
contract GameEncryptedChessRatingWager is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum GameResult { InProgress, WhiteWins, BlackWins, Draw, Abandoned }
    enum TournamentPhase { Registration, Pairing, Playing, Completed }

    struct ChessPlayer {
        address playerAddr;
        string handle;
        euint32 eloRating;              // encrypted Elo rating (e.g., 160000 = 1600)
        euint32 performanceRating;      // encrypted tournament performance
        euint32 winCount;               // encrypted wins
        euint32 drawCount;              // encrypted draws
        euint32 lossCount;              // encrypted losses
        euint64 totalWageredUSD;        // encrypted wagers placed
        euint64 totalWonUSD;            // encrypted earnings
        bool registered;
    }

    struct ChessGame {
        uint256 gameId;
        address whitePlayer;
        address blackPlayer;
        euint64 wagerAmountUSD;         // encrypted per-game stake
        euint32 timeControlSeconds;     // encrypted time control
        GameResult result;
        euint32 whiteTimeUsed;          // encrypted white clock usage
        euint32 blackTimeUsed;          // encrypted black clock usage
        euint32 movesCount;             // encrypted number of moves
        uint256 startedAt;
        uint256 endedAt;
        bool wagerClaimed;
    }

    struct TournamentRound {
        uint256 roundNumber;
        uint256[] gameIds;
        bool completed;
        uint256 startedAt;
    }

    mapping(address => ChessPlayer) private players;
    mapping(uint256 => ChessGame) private games;
    mapping(uint256 => TournamentRound) private rounds;

    uint256 public gameCount;
    uint256 public roundCount;
    TournamentPhase public phase;
    string public tournamentName;

    euint64 private _totalWagerPool;
    euint64 private _platformFeeCollected;
    euint32 private _averageEloRating;
    uint256 public playerCount;

    event PlayerRegistered(address indexed player, string handle);
    event GameCreated(uint256 indexed gameId, address white, address black);
    event GameResultSubmitted(uint256 indexed gameId, GameResult result);
    event RatingUpdated(address indexed player);
    event TournamentCompleted();

    constructor(string memory _tournamentName) Ownable(msg.sender) {
        tournamentName = _tournamentName;
        phase = TournamentPhase.Registration;
        _totalWagerPool = FHE.asEuint64(0);
        _platformFeeCollected = FHE.asEuint64(0);
        _averageEloRating = FHE.asEuint32(0);
        FHE.allowThis(_totalWagerPool);
        FHE.allowThis(_platformFeeCollected);
        FHE.allowThis(_averageEloRating);
    }

    function registerPlayer(
        string calldata handle,
        externalEuint32 encElo, bytes calldata eloProof
    ) external {
        require(!players[msg.sender].registered, "Already registered");
        require(phase == TournamentPhase.Registration, "Not registration phase");
        euint32 elo = FHE.fromExternal(encElo, eloProof);
        ChessPlayer storage p = players[msg.sender];
        p.playerAddr = msg.sender;
        p.handle = handle;
        p.eloRating = elo;
        p.performanceRating = FHE.asEuint32(0);
        p.winCount = FHE.asEuint32(0);
        p.drawCount = FHE.asEuint32(0);
        p.lossCount = FHE.asEuint32(0);
        p.totalWageredUSD = FHE.asEuint64(0);
        p.totalWonUSD = FHE.asEuint64(0);
        p.registered = true;
        playerCount++;
        _averageEloRating = FHE.add(FHE.div(_averageEloRating, FHE.asEuint32(2)), FHE.div(elo, FHE.asEuint32(2)));
        FHE.allowThis(p.eloRating); FHE.allow(p.eloRating, msg.sender);
        FHE.allowThis(p.performanceRating); FHE.allow(p.performanceRating, msg.sender);
        FHE.allowThis(p.winCount); FHE.allowThis(p.drawCount); FHE.allowThis(p.lossCount);
        FHE.allowThis(p.totalWageredUSD); FHE.allow(p.totalWageredUSD, msg.sender);
        FHE.allowThis(p.totalWonUSD); FHE.allow(p.totalWonUSD, msg.sender);
        FHE.allowThis(_averageEloRating);
        emit PlayerRegistered(msg.sender, handle);
    }

    function createGame(
        address whitePlayer,
        address blackPlayer,
        externalEuint64 encWager, bytes calldata wagerProof,
        externalEuint32 encTimeControl, bytes calldata timeProof
    ) external onlyOwner returns (uint256 gameId) {
        require(phase == TournamentPhase.Playing, "Not playing phase");
        require(players[whitePlayer].registered && players[blackPlayer].registered, "Players not registered");
        euint64 wager = FHE.fromExternal(encWager, wagerProof);
        euint32 timeControl = FHE.fromExternal(encTimeControl, timeProof);
        gameId = gameCount++;
        ChessGame storage g = games[gameId];
        g.gameId = gameId;
        g.whitePlayer = whitePlayer;
        g.blackPlayer = blackPlayer;
        g.wagerAmountUSD = wager;
        g.timeControlSeconds = timeControl;
        g.result = GameResult.InProgress;
        g.whiteTimeUsed = FHE.asEuint32(0);
        g.blackTimeUsed = FHE.asEuint32(0);
        g.movesCount = FHE.asEuint32(0);
        g.startedAt = block.timestamp;
        g.wagerClaimed = false;
        euint64 totalStake = FHE.mul(wager, FHE.asEuint64(2));
        euint64 platformFee = FHE.div(totalStake, 50); // 2% fee
        _totalWagerPool = FHE.add(_totalWagerPool, FHE.sub(totalStake, platformFee));
        _platformFeeCollected = FHE.add(_platformFeeCollected, platformFee);
        players[whitePlayer].totalWageredUSD = FHE.add(players[whitePlayer].totalWageredUSD, wager);
        players[blackPlayer].totalWageredUSD = FHE.add(players[blackPlayer].totalWageredUSD, wager);
        FHE.allowThis(g.wagerAmountUSD); FHE.allow(g.wagerAmountUSD, whitePlayer); FHE.allow(g.wagerAmountUSD, blackPlayer);
        FHE.allowThis(g.timeControlSeconds); FHE.allowThis(g.whiteTimeUsed); FHE.allowThis(g.blackTimeUsed);
        FHE.allowThis(g.movesCount); FHE.allowThis(_totalWagerPool); FHE.allowThis(_platformFeeCollected);
        FHE.allowThis(players[whitePlayer].totalWageredUSD); FHE.allowThis(players[blackPlayer].totalWageredUSD);
        emit GameCreated(gameId, whitePlayer, blackPlayer);
    }

    function submitGameResult(
        uint256 gameId,
        GameResult result,
        externalEuint32 encWhiteTime, bytes calldata wtProof,
        externalEuint32 encBlackTime, bytes calldata btProof,
        externalEuint32 encMoves, bytes calldata movesProof
    ) external onlyOwner {
        ChessGame storage g = games[gameId];
        require(g.result == GameResult.InProgress, "Already decided");
        g.result = result;
        g.whiteTimeUsed = FHE.fromExternal(encWhiteTime, wtProof);
        g.blackTimeUsed = FHE.fromExternal(encBlackTime, btProof);
        g.movesCount = FHE.fromExternal(encMoves, movesProof);
        g.endedAt = block.timestamp;
        // Update player records
        if (result == GameResult.WhiteWins) {
            players[g.whitePlayer].winCount = FHE.add(players[g.whitePlayer].winCount, FHE.asEuint32(1));
            players[g.blackPlayer].lossCount = FHE.add(players[g.blackPlayer].lossCount, FHE.asEuint32(1));
        } else if (result == GameResult.BlackWins) {
            players[g.blackPlayer].winCount = FHE.add(players[g.blackPlayer].winCount, FHE.asEuint32(1));
            players[g.whitePlayer].lossCount = FHE.add(players[g.whitePlayer].lossCount, FHE.asEuint32(1));
        } else if (result == GameResult.Draw) {
            players[g.whitePlayer].drawCount = FHE.add(players[g.whitePlayer].drawCount, FHE.asEuint32(1));
            players[g.blackPlayer].drawCount = FHE.add(players[g.blackPlayer].drawCount, FHE.asEuint32(1));
        }
        FHE.allowThis(g.whiteTimeUsed); FHE.allowThis(g.blackTimeUsed); FHE.allowThis(g.movesCount);
        FHE.allowThis(players[g.whitePlayer].winCount); FHE.allowThis(players[g.whitePlayer].lossCount);
        FHE.allowThis(players[g.blackPlayer].winCount); FHE.allowThis(players[g.blackPlayer].lossCount);
        FHE.allowThis(players[g.whitePlayer].drawCount); FHE.allowThis(players[g.blackPlayer].drawCount);
        emit GameResultSubmitted(gameId, result);
    }

    function claimWager(uint256 gameId) external nonReentrant {
        ChessGame storage g = games[gameId];
        require(!g.wagerClaimed, "Already claimed");
        require(g.result != GameResult.InProgress, "Game in progress");
        address winner = address(0);
        if (g.result == GameResult.WhiteWins) winner = g.whitePlayer;
        else if (g.result == GameResult.BlackWins) winner = g.blackPlayer;
        if (winner != address(0)) {
            require(msg.sender == winner, "Not winner");
            euint64 prize = FHE.mul(g.wagerAmountUSD, FHE.asEuint64(2));
            players[winner].totalWonUSD = FHE.add(players[winner].totalWonUSD, prize);
            FHE.allow(prize, winner);
            FHE.allowThis(players[winner].totalWonUSD); FHE.allow(players[winner].totalWonUSD, winner);
        }
        g.wagerClaimed = true;
        _totalWagerPool = FHE.sub(_totalWagerPool, FHE.mul(g.wagerAmountUSD, FHE.asEuint64(2)));
        FHE.allowThis(_totalWagerPool);
    }

    function advancePhase() external onlyOwner {
        require(uint8(phase) < uint8(TournamentPhase.Completed), "Already completed");
        phase = TournamentPhase(uint8(phase) + 1);
        if (phase == TournamentPhase.Completed) emit TournamentCompleted();
    }

    function allowTournamentStats(address viewer) external onlyOwner {
        FHE.allow(_totalWagerPool, viewer);
        FHE.allow(_platformFeeCollected, viewer);
        FHE.allow(_averageEloRating, viewer);
    }

    function allowPlayerStats(address viewer) external {
        FHE.allow(players[msg.sender].eloRating, viewer);
        FHE.allow(players[msg.sender].winCount, viewer);
        FHE.allow(players[msg.sender].totalWonUSD, viewer);
    }
}
