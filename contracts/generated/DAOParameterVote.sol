// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title DAOParameterVote - Confidential governance vote for DAO protocol parameter changes
contract DAOParameterVote is ZamaEthereumConfig, Ownable {
    struct ParameterProposal {
        string paramName;
        uint256 newValue;
        euint64 votesFor;
        euint64 votesAgainst;
        uint256 endBlock;
        bool executed;
        bool finalized;
    }

    mapping(uint256 => ParameterProposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public voted;
    mapping(address => euint64) public votingPower;
    uint256 public proposalCount;
    uint256 public quorumVotes;

    event ProposalCreated(uint256 indexed id, string paramName, uint256 newValue);
    event Voted(uint256 indexed proposalId, address indexed voter);
    event ProposalExecuted(uint256 indexed id);

    constructor(uint256 _quorumVotes) Ownable(msg.sender) {
        quorumVotes = _quorumVotes;
    }

    function setVotingPower(address voter, externalEuint64 encPower, bytes calldata inputProof)
        external
        onlyOwner
    {
        votingPower[voter] = FHE.fromExternal(encPower, inputProof);
        FHE.allowThis(votingPower[voter]);
        FHE.allow(votingPower[voter], voter);
    }

    function propose(string calldata paramName, uint256 newValue, uint256 votingPeriodBlocks)
        external
        returns (uint256 proposalId)
    {
        proposalId = proposalCount++;
        ParameterProposal storage p = proposals[proposalId];
        p.paramName = paramName;
        p.newValue = newValue;
        p.endBlock = block.number + votingPeriodBlocks;
        p.votesFor = FHE.asEuint64(0);
        p.votesAgainst = FHE.asEuint64(0);
        FHE.allowThis(p.votesFor);
        FHE.allowThis(p.votesAgainst);
        emit ProposalCreated(proposalId, paramName, newValue);
    }

    function vote(uint256 proposalId, externalEbool encSupport, bytes calldata inputProof) external {
        require(!voted[proposalId][msg.sender], "Already voted");
        ParameterProposal storage p = proposals[proposalId];
        require(block.number <= p.endBlock, "Voting ended");

        ebool support = FHE.fromExternal(encSupport, inputProof);
        euint64 power = votingPower[msg.sender];

        p.votesFor = FHE.add(p.votesFor, FHE.select(support, power, FHE.asEuint64(0)));
        p.votesAgainst = FHE.add(p.votesAgainst, FHE.select(FHE.not(support), power, FHE.asEuint64(0)));
        FHE.allowThis(p.votesFor);
        FHE.allowThis(p.votesAgainst);
        voted[proposalId][msg.sender] = true;
        emit Voted(proposalId, msg.sender);
    }

    function finalizeProposal(uint256 proposalId) external onlyOwner {
        ParameterProposal storage p = proposals[proposalId];
        require(block.number > p.endBlock, "Not ended");
        require(!p.finalized, "Done");
        p.finalized = true;
        FHE.allow(p.votesFor, owner());
        FHE.allow(p.votesAgainst, owner());
    }
}
