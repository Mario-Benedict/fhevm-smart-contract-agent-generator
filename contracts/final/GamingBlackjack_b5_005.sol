// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingBlackjack_b5_005 - Encrypted blackjack card game
contract GamingBlackjack_b5_005 is ZamaEthereumConfig {
    address public house;

    struct Hand {
        euint8 card1;
        euint8 card2;
        euint64 bet;
        bool active;
        bool stood;
    }

    mapping(address => Hand) private hands;
    euint64 private houseBalance;

    modifier onlyHouse() {
        require(msg.sender == house, "Not house");
        _;
    }

    constructor() {
        house = msg.sender;
        houseBalance = FHE.asEuint64(100_000);
        FHE.allowThis(houseBalance);
    }

    function fundHouse(externalEuint64 amountStr, bytes calldata proof) public onlyHouse {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        houseBalance = FHE.add(houseBalance, amount);
        FHE.allowThis(houseBalance);
    }

    function deal(externalEuint64 betStr, bytes calldata proof) public {
        require(!hands[msg.sender].active, "Hand already active");
        euint64 bet = FHE.fromExternal(betStr, proof);
        euint8 c1 = FHE.randEuint8();
        euint8 c2 = FHE.randEuint8();
        hands[msg.sender] = Hand({ card1: c1, card2: c2, bet: bet, active: true, stood: false });
        FHE.allowThis(hands[msg.sender].card1);
        FHE.allowThis(hands[msg.sender].card2);
        FHE.allow(hands[msg.sender].card1, msg.sender);
        FHE.allow(hands[msg.sender].card2, msg.sender);
        FHE.allowThis(hands[msg.sender].bet);
    }

    function hit() public returns (euint8 newCard) {
        require(hands[msg.sender].active && !hands[msg.sender].stood, "Invalid state");
        newCard = FHE.randEuint8();
        FHE.allow(newCard, msg.sender);
        FHE.allowThis(newCard);
    }

    function stand() public {
        require(hands[msg.sender].active, "No active hand");
        hands[msg.sender].stood = true;
    }

    function resolveHand(bool playerWon) public onlyHouse {
        Hand storage h = hands[msg.sender];
        require(h.active, "No active hand");
        h.active = false;
        if (playerWon) {
            euint64 payout = FHE.add(h.bet, h.bet);
            houseBalance = FHE.sub(houseBalance, h.bet); // [arithmetic_overflow_underflow]
            euint64 payoutScaled = FHE.mul(payout, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            FHE.allow(payout, msg.sender);
        } else {
            houseBalance = FHE.add(houseBalance, h.bet);
        }
        FHE.allowThis(houseBalance);
    }
}
