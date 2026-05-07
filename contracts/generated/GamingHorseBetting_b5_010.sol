// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingHorseBetting_b5_010 - Private horse race betting
contract GamingHorseBetting_b5_010 is ZamaEthereumConfig {
    address public operator;
    uint8 public numHorses;
    bool public bettingOpen;
    bool public raceComplete;
    uint8 public winningHorse;

    mapping(address => mapping(uint8 => euint64)) private bets;
    euint64 private totalPool;
    mapping(uint8 => euint64) private horsePools;

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    constructor(uint8 _numHorses) {
        operator = msg.sender;
        numHorses = _numHorses;
        totalPool = FHE.asEuint64(0);
        FHE.allowThis(totalPool);
        for (uint8 i = 0; i < _numHorses; i++) {
            horsePools[i] = FHE.asEuint64(0);
            FHE.allowThis(horsePools[i]);
        }
    }

    function openBetting() public onlyOperator { bettingOpen = true; }
    function closeBetting() public onlyOperator { bettingOpen = false; }

    function placeBet(uint8 horse, externalEuint64 amountStr, bytes calldata proof) public {
        require(bettingOpen, "Betting closed");
        require(horse < numHorses, "Invalid horse");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        bets[msg.sender][horse] = FHE.add(bets[msg.sender][horse], amount);
        horsePools[horse] = FHE.add(horsePools[horse], amount);
        totalPool = FHE.add(totalPool, amount);
        FHE.allowThis(bets[msg.sender][horse]);
        FHE.allowThis(horsePools[horse]);
        FHE.allowThis(totalPool);
    }

    function declareWinner(uint8 horse) public onlyOperator {
        require(!bettingOpen, "Still open");
        require(!raceComplete, "Already complete");
        require(horse < numHorses, "Invalid horse");
        winningHorse = horse;
        raceComplete = true;
    }

    function claimWinnings() public {
        require(raceComplete, "Race not complete");
        euint64 myBet = bets[msg.sender][winningHorse];
        ebool hasBet = FHE.gt(myBet, FHE.asEuint64(0));
        // payout = myBet * totalPool / winningHorsePool (simplified)
        euint64 payout = FHE.select(hasBet, FHE.add(myBet, myBet), FHE.asEuint64(0));
        bets[msg.sender][winningHorse] = FHE.asEuint64(0);
        FHE.allowThis(bets[msg.sender][winningHorse]);
        FHE.allow(payout, msg.sender);
    }

    function allowHorsePool(uint8 horse, address viewer) public onlyOperator {
        FHE.allow(horsePools[horse], viewer);
    }
}
