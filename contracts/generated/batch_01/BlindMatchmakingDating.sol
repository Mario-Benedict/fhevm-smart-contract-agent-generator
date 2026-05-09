// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BlindMatchmakingDating is ZamaEthereumConfig, Ownable {
    mapping(address => euint64) public personalityVector;
    mapping(address => mapping(address => ebool)) public matches;
    
    constructor() Ownable(msg.sender) {}

    function setPersonality(externalEuint64 vecStr, bytes calldata proof) public {
        personalityVector[msg.sender] = FHE.fromExternal(vecStr, proof);
        FHE.allowThis(personalityVector[msg.sender]);
    }

    function checkMatch(address potentialPartner) public {
        euint64 myVec = personalityVector[msg.sender];
        euint64 theirVec = personalityVector[potentialPartner];
        
        // Exact vector match (simplified). Real usage could be hamming distance
        ebool isMatch = FHE.eq(myVec, theirVec);
        
        matches[msg.sender][potentialPartner] = isMatch;
        matches[potentialPartner][msg.sender] = isMatch;
        
        FHE.allowThis(matches[msg.sender][potentialPartner]);
        FHE.allowThis(matches[potentialPartner][msg.sender]);
    }
}
