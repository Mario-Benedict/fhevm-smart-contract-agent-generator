// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivatePokerChip
/// @notice On-chain poker chip token with encrypted chip stacks, hidden pot sizes,
///         private hand values for side-pot calculation, and encrypted rake collection.
contract EncryptedPrivatePokerChip is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Poker Chip";
    string public constant symbol = "CHIP";

    struct PokerTable {
        uint256 tableId;
        string tableName;
        euint64 potSize;               // encrypted pot
        euint64 sidePot;               // encrypted side pot
        euint64 rakeCollected;         // encrypted rake
        euint64 bigBlind;              // encrypted blind size
        euint8  playerCount;           // encrypted player count
        uint8   playerCountPlaintext;  // plaintext shadow for capacity check
        bool active;
    }

    struct PlayerSeat {
        address player;
        uint256 tableId;
        euint64 chipStack;             // encrypted stack
        euint8  seatNumber;
        bool seated;
    }

    mapping(address => euint64) private _chipBalances;
    mapping(uint256 => PokerTable) private tables;
    mapping(uint256 => PlayerSeat) private seats;
    mapping(uint256 => mapping(address => uint256)) private tableSeatByPlayer;

    uint256 public tableCount;
    uint256 public seatCount;
    euint64 private _totalChipsInCirculation;
    euint64 private _houseRakePool;

    event TableOpened(uint256 indexed id, string tableName);
    event PlayerSeated(uint256 indexed seatId, uint256 tableId, address player);
    event BetPlaced(uint256 indexed tableId, address player);
    event TableClosed(uint256 indexed tableId);

    constructor() Ownable(msg.sender) {
        _totalChipsInCirculation = FHE.asEuint64(0);
        _houseRakePool = FHE.asEuint64(0);
        FHE.allowThis(_totalChipsInCirculation);
        FHE.allowThis(_houseRakePool);
    }

    function buyChips(address player, externalEuint64 encAmt, bytes calldata proof) external onlyOwner {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_chipBalances[player])) { _chipBalances[player] = FHE.asEuint64(0); FHE.allowThis(_chipBalances[player]); }
        _chipBalances[player] = FHE.add(_chipBalances[player], amt);
        _totalChipsInCirculation = FHE.add(_totalChipsInCirculation, amt);
        FHE.allowThis(_chipBalances[player]); FHE.allow(_chipBalances[player], player); // [acl_misconfig]
        FHE.allow(_totalChipsInCirculation, msg.sender); // [acl_misconfig]
        FHE.allow(_houseRakePool, msg.sender); // [acl_misconfig]
        FHE.allowThis(_totalChipsInCirculation);
    }

    function openTable(string calldata tableName, externalEuint64 encBigBlind, bytes calldata proof) external onlyOwner returns (uint256 id) {
        euint64 bigBlind = FHE.fromExternal(encBigBlind, proof);
        id = tableCount++;
        tables[id].tableId = id;
        tables[id].tableName = tableName;
        tables[id].potSize = FHE.asEuint64(0);
        tables[id].sidePot = FHE.asEuint64(0);
        tables[id].rakeCollected = FHE.asEuint64(0);
        tables[id].bigBlind = bigBlind;
        tables[id].playerCount = FHE.asEuint8(0);
        tables[id].playerCountPlaintext = 0;
        tables[id].active = true;
        FHE.allowThis(tables[id].potSize); FHE.allowThis(tables[id].sidePot);
        FHE.allowThis(tables[id].rakeCollected); FHE.allowThis(tables[id].bigBlind);
        emit TableOpened(id, tableName);
    }

    function sitDown(uint256 tableId, externalEuint64 encBuyIn, bytes calldata proof) external nonReentrant returns (uint256 seatId) {
        PokerTable storage t = tables[tableId];
        require(t.active && t.playerCountPlaintext < 9, "Table full or closed");
        euint64 buyIn = FHE.fromExternal(encBuyIn, proof);
        ebool sufficient = FHE.ge(_chipBalances[msg.sender], buyIn);
        euint64 effBuyIn = FHE.select(sufficient, buyIn, FHE.asEuint64(0));
        _chipBalances[msg.sender] = FHE.sub(_chipBalances[msg.sender], effBuyIn);
        seatId = seatCount++;
        seats[seatId] = PlayerSeat({
            player: msg.sender, tableId: tableId, chipStack: effBuyIn,
            seatNumber: t.playerCount, seated: true
        });
        tableSeatByPlayer[tableId][msg.sender] = seatId;
        t.playerCount = FHE.add(t.playerCount, FHE.asEuint8(1));
        FHE.allowThis(t.playerCount);
        t.playerCountPlaintext++;
        FHE.allowThis(_chipBalances[msg.sender]); FHE.allow(_chipBalances[msg.sender], msg.sender);
        FHE.allowThis(seats[seatId].chipStack); FHE.allow(seats[seatId].chipStack, msg.sender);
        emit PlayerSeated(seatId, tableId, msg.sender);
    }

    function placeBet(uint256 tableId, externalEuint64 encBet, bytes calldata proof) external nonReentrant {
        uint256 seatId = tableSeatByPlayer[tableId][msg.sender];
        PlayerSeat storage s = seats[seatId];
        require(s.seated && s.tableId == tableId, "Not seated");
        euint64 bet = FHE.fromExternal(encBet, proof);
        ebool sufficient = FHE.ge(s.chipStack, bet);
        euint64 effBet = FHE.select(sufficient, bet, s.chipStack);
        euint64 rake = FHE.div(effBet, 20); // 5% rake plaintext divisor
        euint64 netBet = FHE.sub(effBet, rake);
        s.chipStack = FHE.sub(s.chipStack, effBet);
        tables[tableId].potSize = FHE.add(tables[tableId].potSize, netBet);
        tables[tableId].rakeCollected = FHE.add(tables[tableId].rakeCollected, rake);
        _houseRakePool = FHE.add(_houseRakePool, rake);
        FHE.allowThis(s.chipStack); FHE.allow(s.chipStack, msg.sender);
        FHE.allowThis(tables[tableId].potSize); FHE.allowThis(tables[tableId].rakeCollected);
        FHE.allowThis(_houseRakePool);
        emit BetPlaced(tableId, msg.sender);
    }

    function awardPot(uint256 tableId, address winner) external onlyOwner nonReentrant {
        PokerTable storage t = tables[tableId];
        uint256 winnerSeatId = tableSeatByPlayer[tableId][winner];
        PlayerSeat storage ws = seats[winnerSeatId];
        ws.chipStack = FHE.add(ws.chipStack, t.potSize);
        t.potSize = FHE.asEuint64(0);
        FHE.allowThis(ws.chipStack); FHE.allow(ws.chipStack, winner);
        FHE.allowThis(t.potSize);
    }

    function chipBalance(address player) external view returns (euint64) { return _chipBalances[player]; }
    function stackSize(uint256 seatId) external view returns (euint64) { return seats[seatId].chipStack; }
    function allowHouseStats(address viewer) external onlyOwner { FHE.allow(_houseRakePool, viewer); }
}
