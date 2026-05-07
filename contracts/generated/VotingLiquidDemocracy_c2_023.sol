// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingLiquidDemocracy_c2_023
/// @notice Liquid democracy: voters can delegate their voting power transitively.
///         All vote weights and delegation chains are tracked with encryption.
contract VotingLiquidDemocracy_c2_023 is ZamaEthereumConfig, Ownable {
    struct Voter {
        euint64 directPower;    // personal voting tokens
        euint64 delegatedPower; // accumulated delegations
        address delegate;
        bool hasVoted;
    }

    mapping(address => Voter) private voters;
    mapping(uint256 => euint64) private proposalVotesFor;
    mapping(uint256 => euint64) private proposalVotesAgainst;
    mapping(uint256 => string) public proposalDescriptions;
    uint256 public proposalCount;
    bool public votingOpen;

    event Delegated(address indexed from, address indexed to);
    event Undelegated(address indexed voter);
    event ProposalAdded(uint256 indexed id);

    constructor() Ownable(msg.sender) {}

    function registerVoter(address voter, externalEuint64 encPower, bytes calldata proof) external onlyOwner {
        euint64 power = FHE.fromExternal(encPower, proof);
        voters[voter].directPower = power;
        FHE.allowThis(voters[voter].directPower);
        FHE.allow(voters[voter].directPower, voter);
    }

    function delegate(address to) external {
        require(to != msg.sender, "Self-delegation");
        require(voters[msg.sender].delegate == address(0), "Already delegated");
        voters[msg.sender].delegate = to;
        // Add sender's power to delegate's delegated power
        voters[to].delegatedPower = FHE.add(voters[to].delegatedPower, voters[msg.sender].directPower);
        FHE.allowThis(voters[to].delegatedPower);
        FHE.allow(voters[to].delegatedPower, to);
        emit Delegated(msg.sender, to);
    }

    function undelegate() external {
        address prev = voters[msg.sender].delegate;
        require(prev != address(0), "Not delegated");
        voters[prev].delegatedPower = FHE.sub(voters[prev].delegatedPower, voters[msg.sender].directPower);
        FHE.allowThis(voters[prev].delegatedPower);
        voters[msg.sender].delegate = address(0);
        emit Undelegated(msg.sender);
    }

    function addProposal(string calldata desc) external onlyOwner returns (uint256 id) {
        id = proposalCount++;
        proposalDescriptions[id] = desc;
        proposalVotesFor[id] = FHE.asEuint64(0);
        proposalVotesAgainst[id] = FHE.asEuint64(0);
        FHE.allowThis(proposalVotesFor[id]);
        FHE.allowThis(proposalVotesAgainst[id]);
        emit ProposalAdded(id);
    }

    function vote(uint256 proposalId, bool support) external {
        require(votingOpen, "Not open");
        Voter storage v = voters[msg.sender];
        require(!v.hasVoted, "Already voted");
        v.hasVoted = true;
        // Effective power = direct + delegated
        euint64 effective = FHE.add(v.directPower, v.delegatedPower);
        if (support) {
            proposalVotesFor[proposalId] = FHE.add(proposalVotesFor[proposalId], effective);
            FHE.allowThis(proposalVotesFor[proposalId]);
        } else {
            proposalVotesAgainst[proposalId] = FHE.add(proposalVotesAgainst[proposalId], effective);
            FHE.allowThis(proposalVotesAgainst[proposalId]);
        }
    }

    function openVoting() external onlyOwner { votingOpen = true; }
    function closeVoting() external onlyOwner { votingOpen = false; }

    function allowVotes(uint256 proposalId, address viewer) external onlyOwner {
        FHE.allow(proposalVotesFor[proposalId], viewer);
        FHE.allow(proposalVotesAgainst[proposalId], viewer);
    }
}
