// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SecureMedicalResearchData is ZamaEthereumConfig, Ownable {
    euint64 public totalAgeAggregated;
    euint64 public totalWeightAggregated;
    euint64 public participantCount;
    
    mapping(address => ebool) public hasParticipated;

    constructor() Ownable(msg.sender) {
        totalAgeAggregated = FHE.asEuint64(0);
        totalWeightAggregated = FHE.asEuint64(0);
        participantCount = FHE.asEuint64(0);
        
        FHE.allowThis(totalAgeAggregated);
        FHE.allowThis(totalWeightAggregated);
        FHE.allowThis(participantCount);
    }

    function submitAnonymizedData(externalEuint64 ageStr, externalEuint64 weightStr, bytes calldata proofA, bytes calldata proofW) public {
        euint64 age = FHE.fromExternal(ageStr, proofA);
        euint64 weight = FHE.fromExternal(weightStr, proofW);
        ebool notParticipated = FHE.not(hasParticipated[msg.sender]);
        
        euint64 ageToAdd = FHE.select(notParticipated, age, FHE.asEuint64(0));
        euint64 weightToAdd = FHE.select(notParticipated, weight, FHE.asEuint64(0));
        euint64 countToAdd = FHE.select(notParticipated, FHE.asEuint64(1), FHE.asEuint64(0));

        totalAgeAggregated = FHE.add(totalAgeAggregated, ageToAdd);
        totalWeightAggregated = FHE.add(totalWeightAggregated, weightToAdd);
        participantCount = FHE.add(participantCount, countToAdd);
        
        hasParticipated[msg.sender] = FHE.select(notParticipated, FHE.asEbool(true), hasParticipated[msg.sender]);

        FHE.allowThis(totalAgeAggregated);
        FHE.allowThis(totalWeightAggregated);
        FHE.allowThis(participantCount);
        FHE.allowThis(hasParticipated[msg.sender]);
    }
}
