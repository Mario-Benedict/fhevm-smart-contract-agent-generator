// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AnonymousDAOVoting is ZamaEthereumConfig, Ownable {
    struct Proposal {
        euint64 yesVotes;
        euint64 noVotes;
        uint256 endTime;
        bool exists;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => ebool)) public hasVotedInfo;
    mapping(address => euint64) public votingPower;

    constructor() Ownable(msg.sender) {}

    function createProposal(uint256 proposalId, uint256 duration) public onlyOwner {
        proposals[proposalId] = Proposal({
            yesVotes: FHE.asEuint64(0),
            noVotes: FHE.asEuint64(0),
            endTime: block.timestamp + duration,
            exists: true
        });
        FHE.allowThis(proposals[proposalId].yesVotes);
        FHE.allowThis(proposals[proposalId].noVotes);
    }

    function assignPower(address voter, externalEuint64 powerStr, bytes calldata proof) public onlyOwner {
        votingPower[voter] = FHE.fromExternal(powerStr, proof);
        FHE.allowThis(votingPower[voter]);
    }

    function vote(uint256 proposalId, externalEbool supportStr, bytes calldata proof) public {
        require(proposals[proposalId].exists, "No proposal");
        require(block.timestamp < proposals[proposalId].endTime, "Ended");

        ebool support = FHE.fromExternal(supportStr, proof);
        ebool notVoted = FHE.not(hasVotedInfo[proposalId][msg.sender]);
        
        // Add power conditionally if not voted
        euint64 powerToAdd = FHE.select(notVoted, votingPower[msg.sender], FHE.asEuint64(0));
        
        euint64 yesAdd = FHE.select(support, powerToAdd, FHE.asEuint64(0));
        euint64 noAdd = FHE.select(support, FHE.asEuint64(0), powerToAdd);

        proposals[proposalId].yesVotes = FHE.add(proposals[proposalId].yesVotes, yesAdd);
        proposals[proposalId].noVotes = FHE.add(proposals[proposalId].noVotes, noAdd);
        
        hasVotedInfo[proposalId][msg.sender] = FHE.select(notVoted, FHE.asEbool(true), hasVotedInfo[proposalId][msg.sender]);

        FHE.allowThis(proposals[proposalId].yesVotes);
        FHE.allowThis(proposals[proposalId].noVotes);
        FHE.allowThis(hasVotedInfo[proposalId][msg.sender]);
    }
}
