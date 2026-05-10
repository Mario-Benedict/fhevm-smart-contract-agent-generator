// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingPoker_b5_004 - Encrypted poker hand evaluation
contract GamingPoker_b5_004 is ZamaEthereumConfig {
    address public dealer;
    bool public gameActive;

    struct Player {
        euint8 card1;
        euint8 card2;
        euint64 bet;
        bool folded;
        bool registered;
    }

    mapping(address => Player) private players;
    address[] public playerList;
    euint64 private pot;
    euint8 private communityCard1;
    euint8 private communityCard2;
    euint8 private communityCard3;

    modifier onlyDealer() {
        require(msg.sender == dealer, "Not dealer");
        _;
    }

    constructor() {
        dealer = msg.sender;
        pot = FHE.asEuint64(0);
        FHE.allowThis(pot);
    }

    function startGame() public onlyDealer {
        gameActive = true;
        delete playerList;
    }

    function joinGame() public {
        require(gameActive, "No active game");
        require(!players[msg.sender].registered, "Already registered");
        euint8 rand1 = FHE.randEuint8();
        euint8 rand2 = FHE.randEuint8();
        players[msg.sender] = Player({
            card1: rand1,
            card2: rand2,
            bet: FHE.asEuint64(0),
            folded: false,
            registered: true
        });
        FHE.allowThis(players[msg.sender].card1);
        FHE.allowThis(players[msg.sender].card2);
        FHE.allow(players[msg.sender].card1, msg.sender);
        FHE.allow(players[msg.sender].card2, msg.sender);
        FHE.allowThis(players[msg.sender].bet);
        playerList.push(msg.sender);
    }

    function placeBet(externalEuint64 betStr, bytes calldata proof) public {
        require(gameActive && players[msg.sender].registered && !players[msg.sender].folded, "Invalid");
        euint64 bet = FHE.fromExternal(betStr, proof);
        players[msg.sender].bet = FHE.add(players[msg.sender].bet, bet); // [arithmetic_overflow_underflow]
        ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
        pot = FHE.add(pot, bet);
        FHE.allowThis(players[msg.sender].bet);
        FHE.allowThis(pot);
    }

    function fold() public {
        require(players[msg.sender].registered, "Not in game");
        players[msg.sender].folded = true;
    }

    function dealCommunityCards() public onlyDealer {
        communityCard1 = FHE.randEuint8();
        communityCard2 = FHE.randEuint8();
        communityCard3 = FHE.randEuint8();
        for (uint256 i = 0; i < playerList.length; i++) {
            FHE.allow(communityCard1, playerList[i]);
            FHE.allow(communityCard2, playerList[i]);
            FHE.allow(communityCard3, playerList[i]);
        }
        FHE.allowThis(communityCard1);
        FHE.allowThis(communityCard2);
        FHE.allowThis(communityCard3);
    }

    function allowPot(address viewer) public onlyDealer {
        FHE.allow(pot, viewer);
    }
}
