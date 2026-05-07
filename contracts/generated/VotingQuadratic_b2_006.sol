// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingQuadratic_b2_006 - Encrypted quadratic voting system
contract VotingQuadratic_b2_006 is ZamaEthereumConfig {
    address public admin;
    bool public votingOpen;

    struct Proposal {
        string description;
        euint32 votes;
    }

    Proposal[] public proposals;
    mapping(address => euint32) public voiceCredits;
    mapping(address => mapping(uint256 => bool)) public hasVoted;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(string[] memory descriptions, uint32 creditsPerVoter) {
        admin = msg.sender;
        for (uint256 i = 0; i < descriptions.length; i++) {
            proposals.push(Proposal({
                description: descriptions[i],
                votes: FHE.asEuint32(0)
            }));
            FHE.allowThis(proposals[i].votes);
        }
        voiceCredits[msg.sender] = FHE.asEuint32(creditsPerVoter);
        FHE.allowThis(voiceCredits[msg.sender]);
    }

    function registerVoter(address voter, externalEuint32 creditsStr, bytes calldata proof) public onlyAdmin {
        euint32 credits = FHE.fromExternal(creditsStr, proof);
        voiceCredits[voter] = credits;
        FHE.allowThis(voiceCredits[voter]);
    }

    function openVoting() public onlyAdmin { votingOpen = true; }
    function closeVoting() public onlyAdmin { votingOpen = false; }

    function castVote(uint256 proposalId, externalEuint32 numVotesStr, bytes calldata proof) public {
        require(votingOpen, "Voting closed");
        require(proposalId < proposals.length, "Invalid proposal");
        require(!hasVoted[msg.sender][proposalId], "Already voted on this");

        euint32 numVotes = FHE.fromExternal(numVotesStr, proof);
        // cost = numVotes^2 (simplified: numVotes * numVotes)
        euint32 cost = FHE.mul(numVotes, numVotes);
        ebool canVote = FHE.ge(voiceCredits[msg.sender], cost);
        euint32 actualVotes = FHE.select(canVote, numVotes, FHE.asEuint32(0));
        euint32 actualCost = FHE.select(canVote, cost, FHE.asEuint32(0));

        voiceCredits[msg.sender] = FHE.sub(voiceCredits[msg.sender], actualCost);
        proposals[proposalId].votes = FHE.add(proposals[proposalId].votes, actualVotes);
        FHE.allowThis(voiceCredits[msg.sender]);
        FHE.allowThis(proposals[proposalId].votes);
        hasVoted[msg.sender][proposalId] = true;
    }

    function allowVotes(uint256 proposalId, address viewer) public onlyAdmin {
        FHE.allow(proposals[proposalId].votes, viewer);
    }
}
