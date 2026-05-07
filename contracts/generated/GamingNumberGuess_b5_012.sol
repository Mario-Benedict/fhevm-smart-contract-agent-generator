// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingNumberGuess_b5_012 - Encrypted number guessing game
contract GamingNumberGuess_b5_012 is ZamaEthereumConfig {
    address public owner;
    euint32 private secretNumber;
    bool public gameActive;
    uint256 public maxGuesses;
    euint64 private jackpot;

    mapping(address => uint256) public guessCount;
    mapping(address => bool) public hasWon;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint256 _maxGuesses) {
        owner = msg.sender;
        maxGuesses = _maxGuesses;
        jackpot = FHE.asEuint64(0);
        FHE.allowThis(jackpot);
    }

    function startGame(externalEuint32 secretStr, bytes calldata proof) public onlyOwner {
        secretNumber = FHE.fromExternal(secretStr, proof);
        gameActive = true;
        FHE.allowThis(secretNumber);
    }

    function fundJackpot(externalEuint64 amountStr, bytes calldata proof) public onlyOwner {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        jackpot = FHE.add(jackpot, amount);
        FHE.allowThis(jackpot);
    }

    function guess(externalEuint32 guessStr, bytes calldata proof) public returns (ebool correct) {
        require(gameActive, "No active game");
        require(!hasWon[msg.sender], "Already won");
        require(guessCount[msg.sender] < maxGuesses, "Out of guesses");

        euint32 g = FHE.fromExternal(guessStr, proof);
        correct = FHE.eq(g, secretNumber);
        guessCount[msg.sender]++;

        // If correct, give jackpot
        euint64 payout = FHE.select(correct, jackpot, FHE.asEuint64(0));
        jackpot = FHE.select(correct, FHE.asEuint64(0), jackpot);
        FHE.allowThis(jackpot);
        FHE.allow(correct, msg.sender);
        FHE.allowThis(correct);
        FHE.allow(payout, msg.sender);
    }

    function endGame() public onlyOwner {
        gameActive = false;
    }

    function allowJackpot(address viewer) public onlyOwner {
        FHE.allow(jackpot, viewer);
    }
}
