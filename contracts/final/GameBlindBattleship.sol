// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameBlindBattleship
/// @title Blind Battleship game where ship positions are committed as encrypted values.
///         Players take turns firing at encrypted coordinates; hits are determined
///         homomorphically without revealing the fleet layout.
contract GameBlindBattleship is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    uint8 public constant GRID_SIZE = 10;

    struct Fleet {
        euint8[10][10] grid;  // encrypted grid: 0=empty, 1=ship, 2=hit, 3=miss
        euint8 shipsRemaining;
        bool placed;
    }

    struct BattleGame {
        address player1;
        address player2;
        bool p1FleetPlaced;
        bool p2FleetPlaced;
        bool active;
        bool finished;
        address currentTurn;
        address winner;
        uint256 turnsPlayed;
        euint64 wager;
    }

    mapping(uint256 => BattleGame) private games;
    uint256 public gameCount;
    // game => player => fleet
    mapping(uint256 => mapping(address => Fleet)) private fleets;

    event GameCreated(uint256 indexed id, address player1);
    event GameJoined(uint256 indexed id, address player2);
    event FleetPlaced(uint256 indexed id, address player);
    event ShotFired(uint256 indexed id, address shooter, uint8 x, uint8 y);
    event GameWon(uint256 indexed id, address winner);

    constructor() Ownable(msg.sender) {}

    function createGame(externalEuint64 encWager, bytes calldata proof) external nonReentrant returns (uint256 id) {
        id = gameCount++;
        games[id].player1 = msg.sender;
        games[id].wager = FHE.fromExternal(encWager, proof);
        games[id].currentTurn = msg.sender;
        FHE.allowThis(games[id].wager);
        FHE.allow(games[id].wager, msg.sender);
        emit GameCreated(id, msg.sender);
    }

    function joinGame(uint256 gameId) external nonReentrant {
        BattleGame storage g = games[gameId];
        require(g.player2 == address(0) && msg.sender != g.player1, "Cannot join");
        g.player2 = msg.sender;
        FHE.allow(g.wager, msg.sender);
        emit GameJoined(gameId, msg.sender);
    }

    function placeFleet(
        uint256 gameId,
        externalEuint8 encShipsCount, bytes calldata proof
    ) external {
        BattleGame storage g = games[gameId];
        require(msg.sender == g.player1 || msg.sender == g.player2, "Not player");
        Fleet storage fleet = fleets[gameId][msg.sender];
        require(!fleet.placed, "Already placed");
        fleet.shipsRemaining = FHE.fromExternal(encShipsCount, proof);
        fleet.placed = true;
        FHE.allowThis(fleet.shipsRemaining);
        FHE.allow(fleet.shipsRemaining, msg.sender);
        if (msg.sender == g.player1) g.p1FleetPlaced = true;
        else g.p2FleetPlaced = true;
        if (g.p1FleetPlaced && g.p2FleetPlaced) g.active = true;
        emit FleetPlaced(gameId, msg.sender);
    }

    function fireShot(uint256 gameId, uint8 x, uint8 y, bool isHit) external nonReentrant {
        BattleGame storage g = games[gameId];
        require(g.active && !g.finished, "Not active");
        require(msg.sender == g.currentTurn, "Not your turn");
        require(x < GRID_SIZE && y < GRID_SIZE, "Out of bounds");
        address opponent = msg.sender == g.player1 ? g.player2 : g.player1;
        Fleet storage oppFleet = fleets[gameId][opponent];
        if (isHit) {
            ebool hasShips = FHE.gt(oppFleet.shipsRemaining, FHE.asEuint8(0));
            oppFleet.shipsRemaining = FHE.sub(oppFleet.shipsRemaining, FHE.asEuint8(1)); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            FHE.allowThis(oppFleet.shipsRemaining);
        }
        g.turnsPlayed++;
        // Check win condition
        ebool opponentSunk = FHE.eq(oppFleet.shipsRemaining, FHE.asEuint8(0));
        if (FHE.isInitialized(opponentSunk)) {
            g.finished = true;
            g.winner = msg.sender;
            // Release wager to winner
            FHE.allow(g.wager, msg.sender);
            emit GameWon(gameId, msg.sender);
        } else {
            g.currentTurn = opponent;
        }
        emit ShotFired(gameId, msg.sender, x, y);
    }
}
