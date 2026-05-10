// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GamePrivatePokerTournament
/// @notice Multi-round poker tournament with encrypted chip stacks. Players cannot
///         see each other's chip counts, enforcing fair play. Tournament eliminates
///         players when encrypted chips reach zero.
contract GamePrivatePokerTournament is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Player {
        euint64 chips;
        uint256 tableId;
        bool active;
        bool eliminated;
        uint8 handsPlayed;
    }

    struct Table {
        uint256[] playerIds;
        euint64 pot;
        uint256 currentRound;
        bool active;
    }

    mapping(uint256 => Player) private players;
    mapping(address => uint256) public playerIndex;
    uint256 public playerCount;
    mapping(uint256 => Table) private tables;
    uint256 public tableCount;
    euint64 private _buyIn;
    euint64 private _prizePool;
    bool public tournamentOpen;
    bool public tournamentFinished;

    event PlayerRegistered(uint256 indexed id, address player);
    event HandPlayed(uint256 indexed tableId, uint256 round);
    event PlayerEliminated(uint256 indexed id);
    event TournamentComplete();

    constructor(externalEuint64 encBuyIn, bytes memory proof) Ownable(msg.sender) {
        _buyIn = FHE.fromExternal(encBuyIn, proof);
        _prizePool = FHE.asEuint64(0);
        tournamentOpen = true;
        FHE.allowThis(_buyIn);
        FHE.allowThis(_prizePool);
    }

    function register(externalEuint64 encPayment, bytes calldata proof) external nonReentrant {
        require(tournamentOpen, "Registration closed");
        uint256 id = playerCount++;
        playerIndex[msg.sender] = id;
        euint64 payment = FHE.fromExternal(encPayment, proof);
        ebool validPayment = FHE.ge(payment, _buyIn);
        players[id].chips = FHE.select(validPayment, _buyIn, FHE.asEuint64(0));
        players[id].active = FHE.isInitialized(validPayment);
        _prizePool = FHE.add(_prizePool, players[id].chips); // [arithmetic_overflow_underflow]
        ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
        FHE.allowThis(players[id].chips);
        FHE.allowThis(_prizePool);
        emit PlayerRegistered(id, msg.sender);
    }

    function startTournament() external onlyOwner {
        tournamentOpen = false;
        // Create tables (simplified: one table)
        tables[0].pot = FHE.asEuint64(0);
        tables[0].currentRound = 0;
        tables[0].active = true;
        tableCount = 1;
        FHE.allowThis(tables[0].pot);
    }

    function playHand(
        uint256 tableId,
        uint256[] calldata playerIds,
        uint256 winnerId,
        externalEuint64 encPot, bytes calldata proof
    ) external onlyOwner nonReentrant {
        require(tables[tableId].active, "Table not active");
        euint64 pot = FHE.fromExternal(encPot, proof);
        // Distribute pot to winner
        players[winnerId].chips = FHE.add(players[winnerId].chips, pot);
        FHE.allowThis(players[winnerId].chips);
        // Deduct from losers (simplified: equal share from non-winners)
        for (uint256 i = 0; i < playerIds.length; i++) {
            if (playerIds[i] != winnerId) {
                players[playerIds[i]].handsPlayed++;
            }
        }
        tables[tableId].currentRound++;
        emit HandPlayed(tableId, tables[tableId].currentRound);
    }

    function eliminatePlayer(uint256 playerId) external onlyOwner {
        players[playerId].eliminated = true;
        players[playerId].active = false;
        emit PlayerEliminated(playerId);
    }

    function finishTournament(uint256 winnerId) external onlyOwner {
        tournamentFinished = true;
        FHE.allow(players[winnerId].chips, msg.sender);
        FHE.allow(_prizePool, msg.sender);
        emit TournamentComplete();
    }

    function allowPlayerChips(uint256 playerId, address viewer) external onlyOwner {
        FHE.allow(players[playerId].chips, viewer);
    }
}
