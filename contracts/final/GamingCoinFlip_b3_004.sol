// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract GamingCoinFlip_b3_004 is ZamaEthereumConfig {
    mapping(address => ebool) private userWins;
    
    function flipCoin(externalEbool choiceStr, bytes calldata inputProof) public {
        ebool choice = FHE.fromExternal(choiceStr, inputProof);
        euint64 randVal = FHE.rem(FHE.randEuint64(), 2);
        euint64 randValWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 randValExposure = FHE.sub(randValWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        
        ebool coinOutcome = FHE.eq(randVal, FHE.asEuint64(1));
        ebool isWin = FHE.eq(choice, coinOutcome);
        
        userWins[msg.sender] = isWin;
        FHE.allowThis(userWins[msg.sender]);
    }
}
