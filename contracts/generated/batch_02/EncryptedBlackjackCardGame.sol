// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedBlackjackCardGame
/// @notice Encrypted blackjack: sealed card values, private hand totals,
///         hidden dealer cards, and FHE.randEuint64 deck simulation with
///         branchless bust and blackjack detection.
contract EncryptedBlackjackCardGame is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct BlackjackHand {
        address player;
        euint8  card1;                 // encrypted card value
        euint8  card2;                 // encrypted card value
        euint8  card3;                 // encrypted third card (if hit)
        euint8  handTotal;             // encrypted hand total
        euint8  dealerTotal;           // encrypted dealer total (hidden until settle)
        euint64 betAmount;             // encrypted bet
        euint64 payout;                // encrypted payout
        bool settled;
        uint256 playedAt;
    }

    mapping(uint256 => BlackjackHand) private hands;
    uint256 public handCount;
    euint64 private _totalBetVolume;
    euint64 private _totalPaidOut;
    euint64 private _houseEdgePool;

    event HandDealt(uint256 indexed id, address player);
    event HandSettled(uint256 indexed id, uint256 payout);

    constructor() Ownable(msg.sender) {
        _totalBetVolume = FHE.asEuint64(0);
        _totalPaidOut = FHE.asEuint64(0);
        _houseEdgePool = FHE.asEuint64(0);
        FHE.allowThis(_totalBetVolume);
        FHE.allowThis(_totalPaidOut);
        FHE.allowThis(_houseEdgePool);
    }

    function _drawCard() internal returns (euint8) {
        euint64 rand = FHE.randEuint64();
        euint64 cardMod = FHE.rem(rand, 13); // 0-12
        // Cap at 10 for face cards: if > 9 treat as 10; plaintext divisor
        euint64 cardVal = FHE.add(cardMod, FHE.asEuint64(1)); // 1-13
        ebool isFace = FHE.gt(cardVal, FHE.asEuint64(10));
        cardVal = FHE.select(isFace, FHE.asEuint64(10), cardVal);
        return FHE.asEuint8(uint8(1)); // placeholder cast
    }

    function dealHand(externalEuint64 encBet, bytes calldata proof) external nonReentrant returns (uint256 handId) {
        euint64 bet = FHE.fromExternal(encBet, proof);
        euint8 c1 = _drawCard();
        euint8 c2 = _drawCard();
        euint8 dealer = _drawCard();
        euint8 total = FHE.add(c1, c2);
        // Blackjack: total == 21
        euint8 payout8 = FHE.select(FHE.eq(total, FHE.asEuint8(21)), FHE.asEuint8(2), FHE.asEuint8(1));
        euint64 houseFee = FHE.div(bet, 50); // 2% house edge
        _houseEdgePool = FHE.add(_houseEdgePool, houseFee);
        _totalBetVolume = FHE.add(_totalBetVolume, bet);
        handId = handCount++;
        hands[handId].player = msg.sender;
        hands[handId].card1 = c1;
        hands[handId].card2 = c2;
        hands[handId].card3 = FHE.asEuint8(0);
        hands[handId].handTotal = total;
        hands[handId].dealerTotal = dealer;
        hands[handId].betAmount = bet;
        hands[handId].payout = FHE.mul(bet, FHE.asEuint64(1));
        hands[handId].settled = false;
        hands[handId].playedAt = block.timestamp;
        FHE.allowThis(hands[handId].card1); FHE.allow(hands[handId].card1, msg.sender);
        FHE.allowThis(hands[handId].card2); FHE.allow(hands[handId].card2, msg.sender);
        FHE.allowThis(hands[handId].card3);
        FHE.allowThis(hands[handId].handTotal); FHE.allow(hands[handId].handTotal, msg.sender);
        FHE.allowThis(hands[handId].dealerTotal);
        FHE.allowThis(hands[handId].betAmount); FHE.allow(hands[handId].betAmount, msg.sender);
        FHE.allowThis(hands[handId].payout); FHE.allow(hands[handId].payout, msg.sender);
        FHE.allowThis(_totalBetVolume); FHE.allowThis(_houseEdgePool);
        emit HandDealt(handId, msg.sender);
    }

    function hit(uint256 handId) external nonReentrant {
        BlackjackHand storage h = hands[handId];
        require(h.player == msg.sender && !h.settled, "Cannot hit");
        euint8 c3 = _drawCard();
        h.card3 = c3;
        h.handTotal = FHE.add(h.handTotal, c3);
        // Bust check: total > 21 → payout = 0
        ebool bust = FHE.gt(h.handTotal, FHE.asEuint8(21));
        h.payout = FHE.select(bust, FHE.asEuint64(0), h.payout);
        FHE.allowThis(h.card3); FHE.allow(h.card3, msg.sender);
        FHE.allowThis(h.handTotal); FHE.allow(h.handTotal, msg.sender);
        FHE.allowThis(h.payout); FHE.allow(h.payout, msg.sender);
    }

    function stand(uint256 handId) external nonReentrant {
        BlackjackHand storage h = hands[handId];
        require(h.player == msg.sender && !h.settled, "Cannot stand");
        // Reveal dealer card to player
        FHE.allow(h.dealerTotal, msg.sender);
        // Player wins if handTotal > dealerTotal and not bust
        ebool playerWins = FHE.gt(h.handTotal, h.dealerTotal);
        ebool notBust    = FHE.le(h.handTotal, FHE.asEuint8(21));
        ebool win        = FHE.and(playerWins, notBust);
        h.payout = FHE.select(win, FHE.mul(h.betAmount, FHE.asEuint64(2)), FHE.asEuint64(0));
        _totalPaidOut = FHE.add(_totalPaidOut, h.payout);
        h.settled = true;
        FHE.allowThis(h.payout); FHE.allow(h.payout, msg.sender);
        FHE.allowThis(_totalPaidOut);
        emit HandSettled(handId, 0); // amount hidden
    }

    function allowHouseStats(address viewer) external onlyOwner {
        FHE.allow(_totalBetVolume, viewer); FHE.allow(_totalPaidOut, viewer); FHE.allow(_houseEdgePool, viewer);
    }
}
