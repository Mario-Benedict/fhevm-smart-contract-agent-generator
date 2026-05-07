// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EncryptedP2PBetting is ZamaEthereumConfig, Ownable {
    address public oracle;
    euint8 public eventResult; // 1 = TeamA, 2 = TeamB
    
    mapping(address => euint8) public bets;
    mapping(address => euint64) public wagers;
    mapping(address => euint64) public returnsDict;

    constructor() Ownable(msg.sender) {
        oracle = msg.sender;
        eventResult = FHE.asEuint8(0);
        FHE.allowThis(eventResult);
    }

    function placeBet(externalEuint8 choiceStr, externalEuint64 amountStr, bytes calldata cp, bytes calldata ap) public {
        bets[msg.sender] = FHE.fromExternal(choiceStr, cp);
        wagers[msg.sender] = FHE.fromExternal(amountStr, ap);
        
        FHE.allowThis(bets[msg.sender]);
        FHE.allowThis(wagers[msg.sender]);
    }

    function resolveEvent(externalEuint8 resStr, bytes calldata proof) public {
        require(msg.sender == oracle, "Only oracle");
        eventResult = FHE.fromExternal(resStr, proof);
        FHE.allowThis(eventResult);
    }

    function calculateReturn(address bettor) public {
        ebool won = FHE.eq(bets[bettor], eventResult);
        
        // 2x return for winning (simple multiplier, plaintext)
        euint64 winnings = FHE.mul(wagers[bettor], 2);
        
        returnsDict[bettor] = FHE.select(won, winnings, FHE.asEuint64(0));
        FHE.allowThis(returnsDict[bettor]);
    }
}
