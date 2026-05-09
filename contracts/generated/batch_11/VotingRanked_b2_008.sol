// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingRanked_b2_008 - Encrypted ranked-choice voting
contract VotingRanked_b2_008 is ZamaEthereumConfig {
    address public admin;
    bool public votingOpen;
    uint8 public numCandidates;

    // First-choice tallies per candidate
    euint32[] public firstChoiceTallies;
    mapping(address => bool) public hasVoted;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(uint8 _numCandidates) {
        admin = msg.sender;
        numCandidates = _numCandidates;
        for (uint8 i = 0; i < _numCandidates; i++) {
            firstChoiceTallies.push(FHE.asEuint32(0));
            FHE.allowThis(firstChoiceTallies[i]);
        }
    }

    function openVoting() public onlyAdmin { votingOpen = true; }
    function closeVoting() public onlyAdmin { votingOpen = false; }

    function castRankedVote(uint8[] calldata rankings) public {
        require(votingOpen, "Voting closed");
        require(!hasVoted[msg.sender], "Already voted");
        require(rankings.length == numCandidates, "Must rank all candidates");
        hasVoted[msg.sender] = true;

        // Record first choice (rank 1)
        for (uint256 i = 0; i < rankings.length; i++) {
            if (rankings[i] == 1) {
                firstChoiceTallies[i] = FHE.add(firstChoiceTallies[i], FHE.asEuint32(1));
                FHE.allowThis(firstChoiceTallies[i]);
                break;
            }
        }
    }

    function allowTally(uint8 candidateIdx, address viewer) public onlyAdmin {
        require(candidateIdx < numCandidates, "Invalid candidate");
        FHE.allow(firstChoiceTallies[candidateIdx], viewer);
    }
}
