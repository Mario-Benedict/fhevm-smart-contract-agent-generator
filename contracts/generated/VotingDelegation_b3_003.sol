// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract VotingDelegation_b3_003 is ZamaEthereumConfig {
    mapping(address => address) public delegates;
    mapping(address => euint32) private votes;

    function delegate(address to) public {
        delegates[msg.sender] = to;
    }

    function castVote(externalEuint32 voteAmountStr, bytes calldata inputProof) public {
        euint32 amount = FHE.fromExternal(voteAmountStr, inputProof);
        address target = delegates[msg.sender] == address(0) ? msg.sender : delegates[msg.sender];
        votes[target] = FHE.add(votes[target], amount);
        FHE.allowThis(votes[target]);
    }
}
