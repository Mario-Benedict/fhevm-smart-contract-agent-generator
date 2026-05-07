// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SecretPokerTable - On-chain poker with encrypted hand strengths and private betting rounds
contract SecretPokerTable is ZamaEthereumConfig, Ownable {
    enum GameState { Waiting, Preflop, Flop, Turn, River, Showdown, Ended }

    struct Player {
        euint8 handStrength;   // encrypted 0-255 hand rank
        euint64 chipStack;
        euint64 currentBet;
        bool folded;
        bool active;
    }

    struct Table {
        GameState state;
        euint64 pot;
        euint64 currentHighBet;
        uint8 playerCount;
        address[] players;
        uint256 roundId;
        bool exists;
    }

    mapping(uint256 => Table) private tables;
    mapping(uint256 => mapping(address => Player)) private tablePlayers;
    uint256 public tableCount;
    address public dealer;

    event TableCreated(uint256 indexed id);
    event PlayerJoined(uint256 indexed tableId, address player);
    event BetPlaced(uint256 indexed tableId, address player);
    event GameAdvanced(uint256 indexed tableId, GameState newState);
    event ShowdownResult(uint256 indexed tableId, address winner);

    modifier onlyDealer() {
        require(msg.sender == dealer || msg.sender == owner(), "Not dealer");
        _;
    }

    constructor(address _dealer) Ownable(msg.sender) {
        dealer = _dealer;
    }

    function createTable() external returns (uint256 id) {
        id = tableCount++;
        tables[id].state = GameState.Waiting;
        tables[id].pot = FHE.asEuint64(0);
        tables[id].currentHighBet = FHE.asEuint64(0);
        tables[id].exists = true;
        FHE.allowThis(tables[id].pot);
        FHE.allowThis(tables[id].currentHighBet);
        emit TableCreated(id);
    }

    function joinTable(uint256 tableId, externalEuint64 encChips, bytes calldata proof) external {
        Table storage t = tables[tableId];
        require(t.state == GameState.Waiting && t.playerCount < 9, "Cannot join");
        euint64 chips = FHE.fromExternal(encChips, proof);
        tablePlayers[tableId][msg.sender] = Player({
            handStrength: FHE.asEuint8(0), chipStack: chips,
            currentBet: FHE.asEuint64(0), folded: false, active: true
        });
        FHE.allowThis(tablePlayers[tableId][msg.sender].handStrength);
        FHE.allow(tablePlayers[tableId][msg.sender].handStrength, msg.sender);
        FHE.allowThis(tablePlayers[tableId][msg.sender].chipStack);
        FHE.allow(tablePlayers[tableId][msg.sender].chipStack, msg.sender);
        FHE.allowThis(tablePlayers[tableId][msg.sender].currentBet);
        t.players.push(msg.sender);
        t.playerCount++;
        emit PlayerJoined(tableId, msg.sender);
    }

    function dealHand(uint256 tableId, address player, externalEuint8 encHandStrength, bytes calldata proof)
        external onlyDealer
    {
        euint8 strength = FHE.fromExternal(encHandStrength, proof);
        tablePlayers[tableId][player].handStrength = strength;
        FHE.allowThis(tablePlayers[tableId][player].handStrength);
        FHE.allow(strength, player); // only player sees their own hand
    }

    function bet(uint256 tableId, externalEuint64 encBet, bytes calldata proof) external {
        Table storage t = tables[tableId];
        Player storage p = tablePlayers[tableId][msg.sender];
        require(!p.folded && p.active, "Cannot bet");
        euint64 betAmt = FHE.fromExternal(encBet, proof);
        ebool hasFunds = FHE.le(betAmt, p.chipStack);
        euint64 actualBet = FHE.select(hasFunds, betAmt, p.chipStack);
        p.chipStack = FHE.sub(p.chipStack, actualBet);
        p.currentBet = FHE.add(p.currentBet, actualBet);
        t.pot = FHE.add(t.pot, actualBet);
        ebool isHigher = FHE.gt(p.currentBet, t.currentHighBet);
        t.currentHighBet = FHE.select(isHigher, p.currentBet, t.currentHighBet);
        FHE.allowThis(p.chipStack); FHE.allow(p.chipStack, msg.sender);
        FHE.allowThis(p.currentBet); FHE.allowThis(t.pot); FHE.allowThis(t.currentHighBet);
        emit BetPlaced(tableId, msg.sender);
    }

    function fold(uint256 tableId) external {
        tablePlayers[tableId][msg.sender].folded = true;
    }

    function advanceState(uint256 tableId) external onlyDealer {
        Table storage t = tables[tableId];
        if (t.state == GameState.Waiting) t.state = GameState.Preflop;
        else if (t.state == GameState.Preflop) t.state = GameState.Flop;
        else if (t.state == GameState.Flop) t.state = GameState.Turn;
        else if (t.state == GameState.Turn) t.state = GameState.River;
        else if (t.state == GameState.River) t.state = GameState.Showdown;
        emit GameAdvanced(tableId, t.state);
    }

    function showdown(uint256 tableId, address winner) external onlyDealer {
        Table storage t = tables[tableId];
        require(t.state == GameState.Showdown, "Not showdown");
        t.state = GameState.Ended;
        tablePlayers[tableId][winner].chipStack = FHE.add(tablePlayers[tableId][winner].chipStack, t.pot);
        t.pot = FHE.asEuint64(0);
        FHE.allowThis(tablePlayers[tableId][winner].chipStack);
        FHE.allow(tablePlayers[tableId][winner].chipStack, winner);
        FHE.allowThis(t.pot);
        emit ShowdownResult(tableId, winner);
    }

    function allowPot(uint256 tableId, address viewer) external onlyDealer {
        FHE.allow(tables[tableId].pot, viewer);
    }
}
