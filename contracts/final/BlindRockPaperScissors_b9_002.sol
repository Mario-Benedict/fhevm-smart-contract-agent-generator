// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract BlindRockPaperScissors_b9_002 is ZamaEthereumConfig {
    address public player1;
    address public player2;
    
    euint8 private p1Choice; // 1=Rock, 2=Paper, 3=Scissors
    euint8 private p2Choice;
    
    euint64 private potAmount;
    mapping(address => euint64) private balances;

    constructor() {
        potAmount = FHE.asEuint64(0);
        FHE.allowThis(potAmount);
    }

    function deposit(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        balances[msg.sender] = FHE.add(balances[msg.sender], amount);
        FHE.allowThis(balances[msg.sender]);
    }

    function commitMove(externalEuint8 choiceStr, externalEuint64 wagerStr, bytes calldata proofC, bytes calldata proofW) public {
        euint8 choice = FHE.fromExternal(choiceStr, proofC);
        euint64 wager = FHE.fromExternal(wagerStr, proofW);
        
        ebool hasFunds = FHE.ge(balances[msg.sender], wager);
        euint64 actualWager = FHE.select(hasFunds, wager, FHE.asEuint64(0));
        euint8 actualChoice = FHE.select(hasFunds, choice, FHE.asEuint8(0));

        ebool _safeSub14 = FHE.ge(balances[msg.sender], actualWager);
        balances[msg.sender] = FHE.select(_safeSub14, FHE.sub(balances[msg.sender], actualWager), FHE.asEuint64(0));
        potAmount = FHE.add(potAmount, actualWager);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(potAmount);

        if (player1 == address(0) || player1 == msg.sender) {
            player1 = msg.sender;
            p1Choice = actualChoice;
            FHE.allowThis(p1Choice);
        } else if (player2 == address(0) || player2 == msg.sender) {
            player2 = msg.sender;
            p2Choice = actualChoice;
            FHE.allowThis(p2Choice);
        }
    }

    function resolve() public {
        require(player1 != address(0) && player2 != address(0), "Waiting for players");
        
        ebool isTie = FHE.eq(p1Choice, p2Choice);
        
        // P1 wins scenarios
        ebool p1R_p2S = FHE.and(FHE.eq(p1Choice, FHE.asEuint8(1)), FHE.eq(p2Choice, FHE.asEuint8(3)));
        ebool p1P_p2R = FHE.and(FHE.eq(p1Choice, FHE.asEuint8(2)), FHE.eq(p2Choice, FHE.asEuint8(1)));
        ebool p1S_p2P = FHE.and(FHE.eq(p1Choice, FHE.asEuint8(3)), FHE.eq(p2Choice, FHE.asEuint8(2)));
        
        ebool p1Wins = FHE.or(FHE.or(p1R_p2S, p1P_p2R), p1S_p2P);
        ebool p2Wins = FHE.and(FHE.not(isTie), FHE.not(p1Wins));

        // Tie = half pot
        euint64 halfPot = FHE.div(potAmount, 2);
        
        euint64 payout1 = FHE.select(isTie, halfPot, FHE.select(p1Wins, potAmount, FHE.asEuint64(0)));
        euint64 payout2 = FHE.select(isTie, halfPot, FHE.select(p2Wins, potAmount, FHE.asEuint64(0)));

        balances[player1] = FHE.add(balances[player1], payout1);
        balances[player2] = FHE.add(balances[player2], payout2);

        potAmount = FHE.asEuint64(0); 

        FHE.allowThis(potAmount);
        FHE.allowThis(balances[player1]);
        FHE.allowThis(balances[player2]);
        
        // Reset so they can play again
        delete player1;
        delete player2;
    }
}
