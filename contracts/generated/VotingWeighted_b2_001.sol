// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract VotingWeighted_b2_001 is ZamaEthereumConfig {
    euint32 private yesVotes;
    euint32 private noVotes;
    mapping(address => euint32) private votingWeight;
    mapping(address => bool) public hasVoted;

    address public owner;

    constructor() {
        owner = msg.sender;
        yesVotes = FHE.asEuint32(0);
        noVotes = FHE.asEuint32(0);
        FHE.allowThis(yesVotes);
        FHE.allowThis(noVotes);
    }

    function setWeight(address voter, externalEuint32 weightStr, bytes calldata inputProof) public {
        require(msg.sender == owner, "Only owner can set weight");
        euint32 weight = FHE.fromExternal(weightStr, inputProof);
        votingWeight[voter] = weight;
        FHE.allowThis(votingWeight[voter]);
    }

    function vote(externalEuint8 voteIndicator, bytes calldata inputProof) public {
        require(!hasVoted[msg.sender], "Already voted");
        hasVoted[msg.sender] = true;

        euint8 v = FHE.fromExternal(voteIndicator, inputProof);
        euint32 weight = votingWeight[msg.sender];
        
        ebool isYes = FHE.eq(v, FHE.asEuint8(1));
        ebool isNo = FHE.eq(v, FHE.asEuint8(0));

        euint32 yesAdd = FHE.select(isYes, weight, FHE.asEuint32(0));
        euint32 noAdd = FHE.select(isNo, weight, FHE.asEuint32(0));

        yesVotes = FHE.add(yesVotes, yesAdd);
        noVotes = FHE.add(noVotes, noAdd);

        FHE.allowThis(yesVotes);
        FHE.allowThis(noVotes);
    }
}
