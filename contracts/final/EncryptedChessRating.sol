// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedChessRating - Encrypted Elo rating system for chess tournament players
contract EncryptedChessRating is ZamaEthereumConfig, Ownable {
    struct ChessPlayer {
        euint16 eloRating;   // encrypted Elo 0-3000
        euint32 gamesPlayed;
        euint32 wins;
        euint32 losses;
        euint32 draws;
        bool registered;
    }

    mapping(address => ChessPlayer) private players;
    mapping(uint256 => bool) public matchRecorded;
    uint256 public matchCount;
    address public arbiter;
    euint16 private _startingElo;

    event PlayerRegistered(address indexed player);
    event MatchRecorded(uint256 indexed matchId, address winner, address loser);

    modifier onlyArbiter() {
        require(msg.sender == arbiter || msg.sender == owner(), "Not arbiter");
        _;
    }

    constructor(address _arbiter, externalEuint16 encStartElo, bytes memory proof) Ownable(msg.sender) {
        arbiter = _arbiter;
        _startingElo = FHE.fromExternal(encStartElo, proof);
        FHE.allowThis(_startingElo);
    }

    function registerPlayer(address p) external onlyArbiter {
        players[p] = ChessPlayer({
            eloRating: _startingElo, gamesPlayed: FHE.asEuint32(0),
            wins: FHE.asEuint32(0), losses: FHE.asEuint32(0), draws: FHE.asEuint32(0), registered: true
        });
        FHE.allowThis(players[p].eloRating);
        FHE.allow(players[p].eloRating, p);
        FHE.allowThis(players[p].gamesPlayed); FHE.allowThis(players[p].wins);
        FHE.allowThis(players[p].losses); FHE.allowThis(players[p].draws);
        emit PlayerRegistered(p);
    }

    function recordMatch(address winner, address loser, bool isDraw) external onlyArbiter {
        require(players[winner].registered && players[loser].registered, "Not registered");
        uint256 matchId = matchCount++;
        matchRecorded[matchId] = true;

        // Simplified Elo: winner gains 16, loser loses 16 (K-factor=16)
        uint16 k = 16;
        if (!isDraw) {
            players[winner].eloRating = FHE.add(players[winner].eloRating, FHE.asEuint16(k));
            players[winner].wins = FHE.add(players[winner].wins, FHE.asEuint32(1));
            // Prevent underflow
            ebool loserCanLose = FHE.ge(players[loser].eloRating, FHE.asEuint16(k));
            euint16 deduct = FHE.select(loserCanLose, FHE.asEuint16(k), players[loser].eloRating);
            ebool _safeSub185 = FHE.ge(players[loser].eloRating, deduct);
            players[loser].eloRating = FHE.select(_safeSub185, FHE.sub(players[loser].eloRating, deduct), FHE.asEuint64(0));
            players[loser].losses = FHE.add(players[loser].losses, FHE.asEuint32(1));
            FHE.allowThis(players[loser].losses);
        } else {
            players[winner].draws = FHE.add(players[winner].draws, FHE.asEuint32(1));
            players[loser].draws = FHE.add(players[loser].draws, FHE.asEuint32(1));
            FHE.allowThis(players[winner].draws); FHE.allowThis(players[loser].draws);
        }
        players[winner].gamesPlayed = FHE.add(players[winner].gamesPlayed, FHE.asEuint32(1));
        players[loser].gamesPlayed = FHE.add(players[loser].gamesPlayed, FHE.asEuint32(1));
        FHE.allowThis(players[winner].eloRating); FHE.allow(players[winner].eloRating, winner);
        FHE.allowThis(players[loser].eloRating); FHE.allow(players[loser].eloRating, loser);
        FHE.allowThis(players[winner].wins); FHE.allowThis(players[winner].gamesPlayed);
        FHE.allowThis(players[loser].gamesPlayed);
        emit MatchRecorded(matchId, winner, loser);
    }

    function allowPlayerStats(address p, address viewer) external {
        require(msg.sender == arbiter || msg.sender == p, "Unauthorized");
        FHE.allow(players[p].eloRating, viewer);
        FHE.allow(players[p].wins, viewer);
        FHE.allow(players[p].gamesPlayed, viewer);
    }
}
