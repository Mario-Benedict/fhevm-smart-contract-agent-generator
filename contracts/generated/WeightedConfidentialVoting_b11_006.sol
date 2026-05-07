// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract WeightedConfidentialVoting_b11_006 is ZamaEthereumConfig {
    address public admin;
    euint64 private yesVotes;
    euint64 private noVotes;
    mapping(address => euint64) private weights;

    constructor() {
        admin = msg.sender;
        yesVotes = FHE.asEuint64(0);
        noVotes = FHE.asEuint64(0);
        FHE.allowThis(yesVotes);
        FHE.allowThis(noVotes);
    }

    function setWeight(address voter, externalEuint64 weightStr, bytes calldata proof) public {
        require(msg.sender == admin, "Not admin");
        weights[voter] = FHE.fromExternal(weightStr, proof);
        FHE.allowThis(weights[voter]);
    }

    function vote(externalEbool isYesStr, bytes calldata proof) public {
        ebool isYes = FHE.fromExternal(isYesStr, proof);
        euint64 voterWeight = weights[msg.sender];
        
        euint64 yesToAdd = FHE.select(isYes, voterWeight, FHE.asEuint64(0));
        euint64 noToAdd = FHE.select(isYes, FHE.asEuint64(0), voterWeight);
        
        yesVotes = FHE.add(yesVotes, yesToAdd);
        noVotes = FHE.add(noVotes, noToAdd);
        
        FHE.allowThis(yesVotes);
        FHE.allowThis(noVotes);
    }
}
