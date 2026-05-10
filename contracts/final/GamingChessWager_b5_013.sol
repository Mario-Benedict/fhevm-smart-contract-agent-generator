// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingChessWager_b5_013 - Encrypted chess wager contract
contract GamingChessWager_b5_013 is ZamaEthereumConfig {
    address public white;
    address public black;
    euint64 private whiteWager;
    euint64 private blackWager;
    address public arbiter;
    bool public gameStarted;
    bool public gameFinished;
    address public winner;

    modifier onlyArbiter() {
        require(msg.sender == arbiter, "Not arbiter");
        _;
    }

    constructor(address _black, address _arbiter) {
        white = msg.sender;
        black = _black;
        arbiter = _arbiter;
        whiteWager = FHE.asEuint64(0);
        blackWager = FHE.asEuint64(0);
        FHE.allowThis(whiteWager);
        FHE.allowThis(blackWager);
    }

    function commitWager(externalEuint64 wagerStr, bytes calldata proof) public {
        require(msg.sender == white || msg.sender == black, "Not a player");
        require(!gameStarted, "Game started");
        euint64 wager = FHE.fromExternal(wagerStr, proof);
        if (msg.sender == white) {
            whiteWager = wager;
            FHE.allowThis(whiteWager);
            FHE.allow(whiteWager, arbiter);
        } else {
            blackWager = wager;
            FHE.allowThis(blackWager);
            FHE.allow(blackWager, arbiter);
        }
    }

    function startGame() public onlyArbiter {
        require(!gameStarted, "Already started");
        gameStarted = true;
    }

    function declareWinner(address _winner) public onlyArbiter {
        require(gameStarted && !gameFinished, "Invalid state");
        require(_winner == white || _winner == black, "Invalid winner");
        gameFinished = true;
        winner = _winner;
        euint64 prize = FHE.add(whiteWager, blackWager); // [arithmetic_overflow_underflow]
        ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
        FHE.allow(prize, _winner);
        FHE.allowThis(prize);
    }

    function declareDraw() public onlyArbiter {
        require(gameStarted && !gameFinished, "Invalid state");
        gameFinished = true;
        FHE.allow(whiteWager, white);
        FHE.allow(blackWager, black);
    }
}
