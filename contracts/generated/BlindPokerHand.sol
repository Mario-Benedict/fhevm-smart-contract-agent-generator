// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title BlindPokerHand - On-chain poker hand with encrypted card assignments
contract BlindPokerHand is ZamaEthereumConfig, Ownable {
    uint8 public constant MAX_PLAYERS = 6;
    uint8 public constant CARDS_PER_PLAYER = 2;

    enum GamePhase { Lobby, Dealing, Betting, Showdown, Complete }

    struct Game {
        address[6] players;
        uint8 playerCount;
        euint8[6][2] holeCards; // [card][player]
        euint64 pot;
        GamePhase phase;
        uint8 dealerSeat;
    }

    mapping(uint256 => Game) public games;
    mapping(uint256 => mapping(address => euint64)) private playerBets;
    mapping(uint256 => mapping(address => bool)) private folded;
    uint256 public gameCount;

    event GameCreated(uint256 indexed gameId);
    event PlayerJoined(uint256 indexed gameId, address indexed player);
    event CardDealt(uint256 indexed gameId, uint8 playerSeat);
    event BetPlaced(uint256 indexed gameId, address indexed player);
    event GameComplete(uint256 indexed gameId, address indexed winner);

    constructor() Ownable(msg.sender) {}

    function createGame() external returns (uint256 gameId) {
        gameId = gameCount++;
        games[gameId].phase = GamePhase.Lobby;
        games[gameId].pot = FHE.asEuint64(0);
        FHE.allowThis(games[gameId].pot);
        emit GameCreated(gameId);
    }

    function joinGame(uint256 gameId) external {
        Game storage g = games[gameId];
        require(g.phase == GamePhase.Lobby, "Not in lobby");
        require(g.playerCount < MAX_PLAYERS, "Full");
        g.players[g.playerCount++] = msg.sender;
        emit PlayerJoined(gameId, msg.sender);
    }

    function dealCards(uint256 gameId) external onlyOwner {
        Game storage g = games[gameId];
        require(g.phase == GamePhase.Lobby && g.playerCount >= 2, "Cannot deal");
        for (uint8 c = 0; c < CARDS_PER_PLAYER; c++) {
            for (uint8 p = 0; p < g.playerCount; p++) {
                euint8 card = FHE.randEuint8();
                euint8 suit = FHE.rem(card, FHE.asEuint8(4));
                euint8 rank = FHE.add(FHE.rem(card, FHE.asEuint8(13)), FHE.asEuint8(1));
                g.holeCards[c][p] = FHE.add(FHE.mul(suit, FHE.asEuint8(13)), rank);
                FHE.allowThis(g.holeCards[c][p]);
                FHE.allow(g.holeCards[c][p], g.players[p]);
                emit CardDealt(gameId, p);
            }
        }
        g.phase = GamePhase.Betting;
    }

    function placeBet(uint256 gameId, externalEuint64 calldata encBet, bytes calldata inputProof) external {
        Game storage g = games[gameId];
        require(g.phase == GamePhase.Betting, "Not betting phase");
        require(!folded[gameId][msg.sender], "Folded");
        euint64 bet = FHE.fromExternal(encBet, inputProof);
        playerBets[gameId][msg.sender] = FHE.add(playerBets[gameId][msg.sender], bet);
        g.pot = FHE.add(g.pot, bet);
        FHE.allowThis(playerBets[gameId][msg.sender]);
        FHE.allowThis(g.pot);
        emit BetPlaced(gameId, msg.sender);
    }

    function fold(uint256 gameId) external {
        require(games[gameId].phase == GamePhase.Betting, "Not betting");
        folded[gameId][msg.sender] = true;
    }

    function settleGame(uint256 gameId, address winner) external onlyOwner {
        Game storage g = games[gameId];
        g.phase = GamePhase.Complete;
        FHE.allow(g.pot, winner);
        emit GameComplete(gameId, winner);
    }
}
