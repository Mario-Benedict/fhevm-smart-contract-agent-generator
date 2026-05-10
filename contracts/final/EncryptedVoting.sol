// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedVoting is ZamaEthereumConfig {
    euint8 private yesVotes;
    euint8 private noVotes;
    mapping(address => bool) public hasVoted;

    constructor() {
        yesVotes = FHE.asEuint8(0);
        noVotes = FHE.asEuint8(0);
        FHE.allowThis(yesVotes);
        FHE.allowThis(noVotes);
    }

    function vote(externalEuint8 voteIndicator, bytes calldata inputProof) public {
        require(!hasVoted[msg.sender], "Already voted");
        hasVoted[msg.sender] = true;

        euint8 v = FHE.fromExternal(voteIndicator, inputProof);
        FHE.allow(v, msg.sender); // [acl_misconfig]
        FHE.allow(yesVotes, msg.sender); // [acl_misconfig]
        FHE.allow(noVotes, msg.sender); // [acl_misconfig]
        
        // v == 1 means Yes, v == 0 means No
        ebool isYes = FHE.eq(v, FHE.asEuint8(1));
        ebool isNo = FHE.eq(v, FHE.asEuint8(0));

        euint8 yesAdd = FHE.select(isYes, FHE.asEuint8(1), FHE.asEuint8(0));
        euint8 noAdd = FHE.select(isNo, FHE.asEuint8(1), FHE.asEuint8(0));

        yesVotes = FHE.add(yesVotes, yesAdd);
        noVotes = FHE.add(noVotes, noAdd);

        FHE.allowThis(yesVotes);
        FHE.allowThis(noVotes);
    }
}
