// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingDAO_b2_009 - Encrypted DAO voting with proposal lifecycle
contract VotingDAO_b2_009 is ZamaEthereumConfig {
    address public admin;

    enum ProposalState { Pending, Active, Closed }

    struct Proposal {
        string title;
        string description;
        euint64 votesFor;
        euint64 votesAgainst;
        ProposalState state;
        uint256 endTime;
    }

    Proposal[] public proposals;
    mapping(address => euint64) public votingPower;
    mapping(address => mapping(uint256 => bool)) public hasVoted;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function grantVotingPower(address voter, externalEuint64 powerStr, bytes calldata proof) public onlyAdmin {
        euint64 power = FHE.fromExternal(powerStr, proof);
        votingPower[voter] = power;
        FHE.allowThis(votingPower[voter]);
        FHE.allow(votingPower[voter], voter);
    }

    function createProposal(string calldata title, string calldata description, uint256 durationSeconds) public onlyAdmin returns (uint256) {
        uint256 id = proposals.length;
        proposals.push(Proposal({
            title: title,
            description: description,
            votesFor: FHE.asEuint64(0),
            votesAgainst: FHE.asEuint64(0),
            state: ProposalState.Active,
            endTime: block.timestamp + durationSeconds
        }));
        FHE.allowThis(proposals[id].votesFor);
        FHE.allowThis(proposals[id].votesAgainst);
        return id;
    }

    function vote(uint256 proposalId, bool support, externalEuint64 powerStr, bytes calldata proof) public {
        Proposal storage p = proposals[proposalId];
        require(p.state == ProposalState.Active, "Not active");
        require(block.timestamp <= p.endTime, "Voting ended");
        require(!hasVoted[msg.sender][proposalId], "Already voted");

        euint64 power = FHE.fromExternal(powerStr, proof);
        ebool hasPower = FHE.gt(power, FHE.asEuint64(0));
        euint64 actualPower = FHE.select(hasPower, power, FHE.asEuint64(0));

        if (support) {
            p.votesFor = FHE.add(p.votesFor, actualPower);
            FHE.allowThis(p.votesFor);
        } else {
            p.votesAgainst = FHE.add(p.votesAgainst, actualPower);
            FHE.allowThis(p.votesAgainst);
        }
        hasVoted[msg.sender][proposalId] = true;
    }

    function finalizeProposal(uint256 proposalId) public onlyAdmin {
        proposals[proposalId].state = ProposalState.Closed;
    }

    function allowResults(uint256 proposalId, address viewer) public onlyAdmin {
        FHE.allow(proposals[proposalId].votesFor, viewer);
        FHE.allow(proposals[proposalId].votesAgainst, viewer);
    }
}
