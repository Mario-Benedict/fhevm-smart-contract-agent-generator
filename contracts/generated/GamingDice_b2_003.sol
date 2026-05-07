// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract GamingDice_b2_003 is ZamaEthereumConfig {
    mapping(address => euint8) private lastRoll;
    mapping(address => euint8) private wins;

    function rollDice(externalEuint8 guessStr, bytes calldata inputProof) public {
        euint8 guess = FHE.fromExternal(guessStr, inputProof);
        
        euint64 randVal = FHE.randEuint64();
        // 1 to 6
        euint64 rem6 = FHE.rem(randVal, 6);
        euint64 dice64 = FHE.add(rem6, FHE.asEuint64(1));
        euint8 diceRoll = FHE.asEuint8(dice64);
        
        lastRoll[msg.sender] = diceRoll;
        FHE.allowThis(lastRoll[msg.sender]);

        ebool isWin = FHE.eq(guess, diceRoll);
        euint8 increment = FHE.select(isWin, FHE.asEuint8(1), FHE.asEuint8(0));
        
        wins[msg.sender] = FHE.add(wins[msg.sender], increment);
        FHE.allowThis(wins[msg.sender]);
    }
}
