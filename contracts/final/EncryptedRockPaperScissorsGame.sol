// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedRockPaperScissorsGame
/// @notice Encrypted PvP Rock-Paper-Scissors: sealed moves via FHE, private wager
///         amounts, and automated winner determination using branchless FHE logic.
contract EncryptedRockPaperScissorsGame is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    // Move: 1=Rock, 2=Paper, 3=Scissors
    enum GameState { WaitingPlayer2, BothCommitted, Resolved, Cancelled }

    struct Game {
        address player1;
        address player2;
        euint8  move1;                 // encrypted move player1
        euint8  move2;                 // encrypted move player2
        euint64 wager;                 // encrypted wager amount
        GameState state;
        address winner;
        uint256 createdAt;
        uint256 commitDeadline;
    }

    mapping(uint256 => Game) private games;
    uint256 public gameCount;
    euint64 private _totalWagerVolume;
    euint64 private _houseRevenue;

    event GameCreated(uint256 indexed id, address player1);
    event Player2Joined(uint256 indexed id, address player2);
    event GameResolved(uint256 indexed id, address winner);

    constructor() Ownable(msg.sender) {
        _totalWagerVolume = FHE.asEuint64(0);
        _houseRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalWagerVolume);
        FHE.allowThis(_houseRevenue);
    }

    function createGame(
        externalEuint8 encMove, bytes calldata moveProof,
        externalEuint64 encWager, bytes calldata wagerProof,
        uint256 commitWindowHours
    ) external nonReentrant returns (uint256 id) {
        euint8  move  = FHE.fromExternal(encMove, moveProof);
        euint64 wager = FHE.fromExternal(encWager, wagerProof);
        id = gameCount++;
        games[id].player1 = msg.sender;
        games[id].player2 = address(0);
        games[id].move1 = move;
        games[id].move2 = FHE.asEuint8(0);
        games[id].wager = wager;
        games[id].state = GameState.WaitingPlayer2;
        games[id].winner = address(0);
        games[id].createdAt = block.timestamp;
        games[id].commitDeadline = block.timestamp + commitWindowHours * 1 hours;
        FHE.allowThis(games[id].move1);
        FHE.allowThis(games[id].move2);
        FHE.allowThis(games[id].wager); FHE.allow(games[id].wager, msg.sender); // [acl_misconfig]
        FHE.allow(_totalWagerVolume, msg.sender); // [acl_misconfig]
        FHE.allow(_houseRevenue, msg.sender); // [acl_misconfig]
        emit GameCreated(id, msg.sender);
    }

    function joinGame(uint256 gameId, externalEuint8 encMove, bytes calldata moveProof) external nonReentrant {
        Game storage g = games[gameId];
        require(g.state == GameState.WaitingPlayer2 && block.timestamp < g.commitDeadline, "Cannot join");
        require(msg.sender != g.player1, "Cannot play yourself");
        g.move2 = FHE.fromExternal(encMove, moveProof);
        g.player2 = msg.sender;
        g.state = GameState.BothCommitted;
        FHE.allowThis(g.move2);
        emit Player2Joined(gameId, msg.sender);
    }

    function resolveGame(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        require(g.state == GameState.BothCommitted, "Not committed");
        // Branchless winner determination:
        // draw: m1==m2 | p1 wins: (1,3),(2,1),(3,2) | p2 wins: (1,2),(2,3),(3,1)
        ebool draw = FHE.eq(g.move1, g.move2);
        // Rock(1) beats Scissors(3): m1=1 && m2=3
        ebool p1R_p2S = FHE.and(FHE.eq(g.move1, FHE.asEuint8(1)), FHE.eq(g.move2, FHE.asEuint8(3)));
        // Paper(2) beats Rock(1): m1=2 && m2=1
        ebool p1P_p2R = FHE.and(FHE.eq(g.move1, FHE.asEuint8(2)), FHE.eq(g.move2, FHE.asEuint8(1)));
        // Scissors(3) beats Paper(2): m1=3 && m2=2
        ebool p1S_p2P = FHE.and(FHE.eq(g.move1, FHE.asEuint8(3)), FHE.eq(g.move2, FHE.asEuint8(2)));
        ebool p1Wins = FHE.or(FHE.or(p1R_p2S, p1P_p2R), p1S_p2P);
        // Prize: 95% to winner (5% house), plaintext divisor
        euint64 prize = FHE.div(FHE.mul(g.wager, 95), 100);
        euint64 house = FHE.sub(g.wager, prize);
        _totalWagerVolume = FHE.add(_totalWagerVolume, g.wager);
        _houseRevenue = FHE.add(_houseRevenue, house);
        // Reveal moves to both players
        FHE.allow(g.move1, g.player1); FHE.allow(g.move1, g.player2);
        FHE.allow(g.move2, g.player1); FHE.allow(g.move2, g.player2);
        FHE.allow(prize, g.player1); FHE.allow(prize, g.player2);
        g.winner = FHE.isInitialized(p1Wins) ? g.player1 : g.player2;
        if (FHE.isInitialized(draw)) g.winner = address(0); // draw
        g.state = GameState.Resolved;
        FHE.allowThis(_totalWagerVolume); FHE.allowThis(_houseRevenue);
        emit GameResolved(gameId, g.winner);
    }

    function allowStatsView(address viewer) external onlyOwner {
        FHE.allow(_totalWagerVolume, viewer); FHE.allow(_houseRevenue, viewer);
    }
    function getMove1(uint256 gameId) external view returns (euint8) { return games[gameId].move1; }
    function getWager(uint256 gameId) external view returns (euint64) { return games[gameId].wager; }
}
