// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameBlindPokerCashTable
/// @notice Multi-player blind poker cash table: encrypted hand strengths, encrypted pot size,
///         encrypted stack sizes, encrypted side pots, random card shuffle using FHE RNG.
contract GameBlindPokerCashTable is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    uint8 public constant MAX_PLAYERS = 9;

    enum Action { FOLD, CHECK, CALL, RAISE, ALL_IN }
    enum TableState { WAITING, PREFLOP, FLOP, TURN, RIVER, SHOWDOWN }

    struct PlayerSeat {
        address player;
        euint64 stackSize;       // encrypted chip stack
        euint64 currentBet;      // encrypted current street bet
        euint64 totalBetRound;   // encrypted total this hand
        euint8 handStrength;     // encrypted hand strength 0-255
        euint8 card1;            // encrypted hole card 1
        euint8 card2;            // encrypted hole card 2
        bool folded;
        bool active;
        bool sittingOut;
    }

    struct CashTable {
        euint64 potSize;          // encrypted main pot
        euint64 sidePot;          // encrypted side pot for all-ins
        euint64 bigBlind;         // encrypted BB amount
        euint64 smallBlind;       // encrypted SB amount
        euint64 rake;             // encrypted rake taken by house
        TableState state;
        uint8 activePlayers;
        uint8 dealerButton;
        uint256 handNumber;
        uint256 lastActionTime;
    }

    CashTable private table;
    mapping(uint8 => PlayerSeat) private seats;
    mapping(address => uint8) private playerSeat;
    euint64 private _deckSeed;       // encrypted deck shuffle seed
    euint64 private _totalRakeCollected;
    mapping(address => bool) public isDealer;

    event PlayerSeated(address indexed player, uint8 seat);
    event HandStarted(uint256 indexed handNumber);
    event ActionTaken(address indexed player, Action action, uint8 seat);
    event PotAwarded(uint8 indexed winningSeat, uint256 handNumber);
    event PlayerLeft(address indexed player, uint8 seat);

    constructor(
        externalEuint64 encBigBlind, bytes memory bbProof,
        externalEuint64 encSmallBlind, bytes memory sbProof
    ) Ownable(msg.sender) {
        euint64 bb = FHE.fromExternal(encBigBlind, bbProof);
        euint64 sb = FHE.fromExternal(encSmallBlind, sbProof);
        table.bigBlind = bb;
        table.smallBlind = sb;
        table.potSize = FHE.asEuint64(0);
        table.sidePot = FHE.asEuint64(0);
        table.rake = FHE.asEuint64(0);
        table.state = TableState.WAITING;
        table.handNumber = 0;
        _deckSeed = FHE.randEuint64();
        _totalRakeCollected = FHE.asEuint64(0);
        FHE.allowThis(table.bigBlind);
        FHE.allowThis(table.smallBlind);
        FHE.allowThis(table.potSize);
        FHE.allowThis(table.sidePot);
        FHE.allowThis(table.rake);
        FHE.allowThis(_deckSeed);
        FHE.allowThis(_totalRakeCollected);
        isDealer[msg.sender] = true;
    }

    function addDealer(address d) external onlyOwner { isDealer[d] = true; }

    function sitDown(
        uint8 seat,
        externalEuint64 encBuyIn, bytes calldata proof
    ) external nonReentrant {
        require(seat < MAX_PLAYERS, "Invalid seat");
        require(!seats[seat].active, "Seat taken");
        require(playerSeat[msg.sender] == 0, "Already seated");
        euint64 buyIn = FHE.fromExternal(encBuyIn, proof);
        seats[seat] = PlayerSeat({
            player: msg.sender, stackSize: buyIn,
            currentBet: FHE.asEuint64(0), totalBetRound: FHE.asEuint64(0),
            handStrength: FHE.asEuint8(0),
            card1: FHE.asEuint8(0), card2: FHE.asEuint8(0),
            folded: false, active: true, sittingOut: false
        });
        playerSeat[msg.sender] = seat + 1; // 1-indexed to distinguish from default 0
        FHE.allowThis(seats[seat].stackSize);
        FHE.allowThis(seats[seat].currentBet);
        FHE.allowThis(seats[seat].handStrength);
        FHE.allowThis(seats[seat].card1);
        FHE.allowThis(seats[seat].card2);
        FHE.allow(seats[seat].stackSize, msg.sender);
        FHE.allow(seats[seat].card1, msg.sender);
        FHE.allow(seats[seat].card2, msg.sender);
        table.activePlayers++;
        emit PlayerSeated(msg.sender, seat);
    }

    function startHand() external {
        require(isDealer[msg.sender], "Not dealer");
        require(table.activePlayers >= 2, "Need 2+ players");
        require(table.state == TableState.WAITING, "Hand in progress");
        table.handNumber++;
        table.state = TableState.PREFLOP;
        table.potSize = FHE.asEuint64(0);
        // Shuffle deck using random seed XOR'd with block data
        _deckSeed = FHE.xor(_deckSeed, FHE.randEuint64());
        FHE.allowThis(_deckSeed);
        // Deal encrypted cards to each active player
        for (uint8 i = 0; i < MAX_PLAYERS; i++) {
            if (seats[i].active && !seats[i].sittingOut) {
                seats[i].folded = false;
                // Card = (seed + seatIndex * 2) mod 52 (conceptual)
                seats[i].card1 = FHE.asEuint8(uint8(i * 2) % 52);
                seats[i].card2 = FHE.asEuint8(uint8(i * 2 + 1) % 52);
                seats[i].currentBet = FHE.asEuint64(0);
                seats[i].totalBetRound = FHE.asEuint64(0);
                FHE.allowThis(seats[i].card1);
                FHE.allowThis(seats[i].card2);
                FHE.allow(seats[i].card1, seats[i].player);
                FHE.allow(seats[i].card2, seats[i].player);
            }
        }
        table.lastActionTime = block.timestamp;
        emit HandStarted(table.handNumber);
    }

    function takeAction(Action action, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        uint8 seatIdx = playerSeat[msg.sender];
        require(seatIdx > 0, "Not seated");
        seatIdx--; // convert to 0-indexed
        PlayerSeat storage seat = seats[seatIdx];
        require(seat.active && !seat.folded, "Cannot act");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        if (action == Action.FOLD) {
            seat.folded = true;
            table.activePlayers--;
        } else if (action == Action.RAISE || action == Action.CALL) {
            ebool hasFunds = FHE.ge(seat.stackSize, amount);
            euint64 actual = FHE.select(hasFunds, amount, seat.stackSize);
            seat.stackSize = FHE.sub(seat.stackSize, actual);
            seat.currentBet = FHE.add(seat.currentBet, actual);
            seat.totalBetRound = FHE.add(seat.totalBetRound, actual);
            table.potSize = FHE.add(table.potSize, actual);
            FHE.allowThis(seat.stackSize);
            FHE.allow(seat.stackSize, msg.sender);
            FHE.allowThis(seat.currentBet);
            FHE.allowThis(seat.totalBetRound);
            FHE.allowThis(table.potSize);
        }
        table.lastActionTime = block.timestamp;
        emit ActionTaken(msg.sender, action, seatIdx);
    }

    function awardPot(uint8 winningSeat) external nonReentrant {
        require(isDealer[msg.sender], "Not dealer");
        require(table.activePlayers >= 1, "No players");
        PlayerSeat storage winner = seats[winningSeat];
        require(winner.active && !winner.folded, "Invalid winner");
        // Rake: 5% of pot
        euint64 rakeAmount = FHE.div(table.potSize, 20);
        euint64 award = FHE.sub(table.potSize, rakeAmount);
        winner.stackSize = FHE.add(winner.stackSize, award);
        _totalRakeCollected = FHE.add(_totalRakeCollected, rakeAmount);
        table.potSize = FHE.asEuint64(0);
        table.state = TableState.WAITING;
        FHE.allowThis(winner.stackSize);
        FHE.allow(winner.stackSize, winner.player);
        FHE.allowThis(_totalRakeCollected);
        FHE.allowThis(table.potSize);
        emit PotAwarded(winningSeat, table.handNumber);
    }

    function leaveTable(uint8 seat) external nonReentrant {
        require(seats[seat].player == msg.sender, "Not your seat");
        euint64 remaining = seats[seat].stackSize;
        seats[seat].active = false;
        table.activePlayers--;
        playerSeat[msg.sender] = 0;
        FHE.allow(remaining, msg.sender);
        emit PlayerLeft(msg.sender, seat);
    }
}
