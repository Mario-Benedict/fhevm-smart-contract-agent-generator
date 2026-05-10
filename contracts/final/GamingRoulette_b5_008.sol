// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingRoulette_b5_008 - Encrypted roulette game with private bets
contract GamingRoulette_b5_008 is ZamaEthereumConfig {
    address public owner;
    euint64 private housePool;
    euint8 private lastResult;

    struct Bet {
        euint64 amount;
        uint8 betNumber; // 0-36
        bool claimed;
    }

    mapping(address => Bet) private currentBets;
    mapping(address => euint64) private winnings;
    bool public bettingOpen;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        housePool = FHE.asEuint64(0);
        FHE.allowThis(housePool);
    }

    function fundHouse(externalEuint64 amountStr, bytes calldata proof) public onlyOwner {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        housePool = FHE.add(housePool, amount);
        FHE.allowThis(housePool);
    }

    function openBetting() public onlyOwner { bettingOpen = true; }
    function closeBetting() public onlyOwner { bettingOpen = false; }

    function placeBet(externalEuint64 amountStr, bytes calldata proof, uint8 betNumber) public {
        require(bettingOpen, "Betting closed");
        require(betNumber <= 36, "Invalid number");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        currentBets[msg.sender] = Bet({ amount: amount, betNumber: betNumber, claimed: false });
        housePool = FHE.add(housePool, amount);
        FHE.allowThis(currentBets[msg.sender].amount);
        FHE.allowThis(housePool);
    }

    function spin() public onlyOwner returns (euint8) {
        lastResult = FHE.randEuint8();
        FHE.allowThis(lastResult);
        return lastResult;
    }

    function revealAndClaim(uint8 resultNumber) public {
        Bet storage b = currentBets[msg.sender];
        require(!b.claimed, "Already claimed");
        b.claimed = true;

        if (b.betNumber == resultNumber) {
            // Win: payout 35x
            euint64 payout = FHE.mul(b.amount, FHE.asEuint64(35)); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            ebool houseOk = FHE.ge(housePool, payout);
            euint64 actualPayout = FHE.select(houseOk, payout, housePool);
            housePool = FHE.sub(housePool, actualPayout);
            winnings[msg.sender] = FHE.add(winnings[msg.sender], actualPayout);
            FHE.allowThis(housePool);
            FHE.allowThis(winnings[msg.sender]);
        }
    }

    function claimWinnings() public {
        euint64 w = winnings[msg.sender];
        winnings[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(winnings[msg.sender]);
        FHE.allow(w, msg.sender);
    }
}
