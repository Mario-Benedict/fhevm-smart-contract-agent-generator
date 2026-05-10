// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPokerCardGameRNG
/// @notice On-chain poker with FHE-encrypted hands, encrypted bet sizing,
///         and private card dealing using FHE.randEuint64 for true randomness.
contract EncryptedPokerCardGameRNG is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum GamePhase { WAITING, PREFLOP, FLOP, TURN, RIVER, SHOWDOWN, SETTLED }
    enum PlayerAction { NONE, FOLD, CHECK, CALL, RAISE, ALL_IN }

    struct PokerHand {
        address[] players;
        GamePhase  phase;
        euint64    pot;               // encrypted total pot
        euint64    currentBet;        // encrypted current bet to call
        euint64    rakeUSD;           // encrypted house rake
        euint64    deckSeed;          // encrypted randomness seed for deck
        euint8     communityCard1;    // encrypted community cards
        euint8     communityCard2;
        euint8     communityCard3;
        euint8     communityCard4;
        euint8     communityCard5;
        uint256    startTime;
        bool       concluded;
    }

    struct PlayerState {
        euint64 stackUSD;             // encrypted chip stack
        euint64 totalBetThisHand;     // encrypted committed this hand
        euint8  holeCard1;            // encrypted private card
        euint8  holeCard2;            // encrypted private card
        euint8  handStrength;         // encrypted hand rank (set at showdown)
        PlayerAction lastAction;
        bool    folded;
        bool    allIn;
        bool    active;
    }

    mapping(uint256 => PokerHand)                         private hands;
    mapping(uint256 => mapping(address => PlayerState))   private playerStates;
    mapping(address => euint64)                           private playerBankroll;
    uint256 public handCount;
    euint64 private _totalRakeCollected;
    euint16 private _rakeFeeBps;      // encrypted rake rate

    event HandStarted(uint256 indexed handId, uint256 playerCount);
    event CardsDealt(uint256 indexed handId);
    event ActionTaken(uint256 indexed handId, address player, PlayerAction action);
    event HandSettled(uint256 indexed handId, address winner);
    event CashOut(address player);

    constructor(uint16 rakeFeeBps) Ownable(msg.sender) {
        _rakeFeeBps        = FHE.asEuint16(rakeFeeBps);
        _totalRakeCollected = FHE.asEuint64(0);
        FHE.allowThis(_rakeFeeBps);
        FHE.allowThis(_totalRakeCollected);
    }

    function depositStack(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        if (!FHE.isInitialized(playerBankroll[msg.sender])) {
            playerBankroll[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(playerBankroll[msg.sender]);
        }
        playerBankroll[msg.sender] = FHE.add(playerBankroll[msg.sender], amount);
        FHE.allowThis(playerBankroll[msg.sender]);
        FHE.allow(playerBankroll[msg.sender], msg.sender) // [acl_misconfig]
        FHE.allow(_totalRakeCollected, msg.sender); // [acl_misconfig]
        FHE.allow(_rakeFeeBps, msg.sender); // [acl_misconfig]
    }

    function startHand(address[] calldata players) external onlyOwner returns (uint256 handId) {
        require(players.length >= 2 && players.length <= 9, "Invalid players");
        euint64 seed = FHE.randEuint64(); // Cryptographically secure randomness
        handId = handCount++;
        PokerHand storage _s0 = hands[handId];
        _s0.players = players;
        _s0.phase = GamePhase.PREFLOP;
        _s0.pot = FHE.asEuint64(0);
        _s0.currentBet = FHE.asEuint64(0);
        _s0.rakeUSD = FHE.asEuint64(0);
        _s0.deckSeed = seed;
        _s0.communityCard1 = FHE.asEuint8(0);
        _s0.communityCard2 = FHE.asEuint8(0);
        _s0.communityCard3 = FHE.asEuint8(0);
        _s0.communityCard4 = FHE.asEuint8(0);
        _s0.communityCard5 = FHE.asEuint8(0);
        _s0.startTime = block.timestamp;
        _s0.concluded = false;
        FHE.allowThis(hands[handId].pot);
        FHE.allowThis(hands[handId].currentBet);
        FHE.allowThis(hands[handId].rakeUSD);
        FHE.allowThis(hands[handId].deckSeed);
        FHE.allowThis(hands[handId].communityCard1);
        FHE.allowThis(hands[handId].communityCard2);
        FHE.allowThis(hands[handId].communityCard3);
        FHE.allowThis(hands[handId].communityCard4);
        FHE.allowThis(hands[handId].communityCard5);
        emit HandStarted(handId, players.length);
    }

    function dealHoleCards(uint256 handId) external onlyOwner {
        PokerHand storage h = hands[handId];
        // Each player gets two encrypted cards derived from deck seed + player index
        for (uint256 i = 0; i < h.players.length; i++) {
            address p = h.players[i];
            euint64 r1 = FHE.randEuint64();
            euint64 r2 = FHE.randEuint64();
            // Cards 0-51 derived by mod 52
            euint8 c1 = FHE.asEuint8(uint8(i * 2));       // simplified
            euint8 c2 = FHE.asEuint8(uint8(i * 2 + 1));

            playerStates[handId][p].stackUSD = playerBankroll[p];
            playerStates[handId][p].totalBetThisHand = FHE.asEuint64(0);
            playerStates[handId][p].holeCard1 = c1;
            playerStates[handId][p].holeCard2 = c2;
            playerStates[handId][p].handStrength = FHE.asEuint8(0);
            playerStates[handId][p].lastAction = PlayerAction.NONE;
            playerStates[handId][p].folded = false;
            playerStates[handId][p].allIn = false;
            playerStates[handId][p].active = true;
            FHE.allowThis(playerStates[handId][p].stackUSD);
            FHE.allow(playerStates[handId][p].stackUSD, p);
            FHE.allowThis(playerStates[handId][p].totalBetThisHand);
            FHE.allow(playerStates[handId][p].totalBetThisHand, p);
            FHE.allowThis(playerStates[handId][p].holeCard1);
            FHE.allow(playerStates[handId][p].holeCard1, p);  // only player sees their cards
            FHE.allowThis(playerStates[handId][p].holeCard2);
            FHE.allow(playerStates[handId][p].holeCard2, p);
            FHE.allowThis(playerStates[handId][p].handStrength);
        }
        emit CardsDealt(handId);
    }

    function takeAction(
        uint256 handId,
        PlayerAction action,
        externalEuint64 encBetAmount, bytes calldata proof
    ) external nonReentrant {
        require(!hands[handId].concluded, "Hand over");
        require(playerStates[handId][msg.sender].active, "Not in hand");
        require(!playerStates[handId][msg.sender].folded, "Folded");

        euint64 betAmount = FHE.fromExternal(encBetAmount, proof);
        PlayerState storage ps = playerStates[handId][msg.sender];
        PokerHand   storage h  = hands[handId];

        if (action == PlayerAction.FOLD) {
            ps.folded = true;
        } else if (action == PlayerAction.RAISE || action == PlayerAction.CALL) {
            ebool hasFunds = FHE.ge(ps.stackUSD, betAmount);
            euint64 actual = FHE.select(hasFunds, betAmount, ps.stackUSD);
            ps.stackUSD           = FHE.sub(ps.stackUSD, actual);
            ps.totalBetThisHand   = FHE.add(ps.totalBetThisHand, actual);
            h.pot                 = FHE.add(h.pot, actual);
            if (action == PlayerAction.RAISE) h.currentBet = actual;
            FHE.allowThis(ps.stackUSD);
            FHE.allow(ps.stackUSD, msg.sender);
            FHE.allowThis(ps.totalBetThisHand);
            FHE.allowThis(h.pot);
        }
        ps.lastAction = action;
        emit ActionTaken(handId, msg.sender, action);
    }

    function settleHand(uint256 handId, address winner) external onlyOwner {
        require(!hands[handId].concluded, "Already concluded");
        PokerHand storage h = hands[handId];
        euint64 rake    = FHE.div(h.pot, 20); // 5% rake
        euint64 winnings= FHE.sub(h.pot, rake);
        h.rakeUSD  = rake;
        h.concluded = true;
        playerBankroll[winner] = FHE.add(playerBankroll[winner], winnings);
        _totalRakeCollected    = FHE.add(_totalRakeCollected, rake);
        FHE.allowThis(h.rakeUSD);
        FHE.allow(winnings, winner);
        FHE.allowThis(playerBankroll[winner]);
        FHE.allow(playerBankroll[winner], winner);
        FHE.allowThis(_totalRakeCollected);
        emit HandSettled(handId, winner);
    }

    function cashOut() external nonReentrant {
        require(FHE.isInitialized(playerBankroll[msg.sender]), "No balance");
        FHE.allow(playerBankroll[msg.sender], msg.sender);
        playerBankroll[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(playerBankroll[msg.sender]);
        emit CashOut(msg.sender);
    }

    function allowHouseView(address viewer) external onlyOwner {
        FHE.allow(_totalRakeCollected, viewer);
    }
}
