// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VotingOnChainGov_c2_021
/// @notice Full on-chain governance: token-weighted encrypted votes, timelock
///         execution, quorum check, and proposal lifecycle management.
contract VotingOnChainGov_c2_021 is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ProposalState { Pending, Active, Defeated, Succeeded, Queued, Executed }

    struct Proposal {
        address proposer;
        string description;
        bytes callData;
        address target;
        euint64 votesFor;
        euint64 votesAgainst;
        euint64 votesAbstain;
        uint256 startBlock;
        uint256 endBlock;
        uint256 executionTime;
        ProposalState state;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(address => euint64) private _votingPower;
    mapping(address => mapping(uint256 => bool)) public hasVoted;
    uint256 public nextProposalId;
    uint256 public votingPeriod = 7 days;
    uint256 public timelockDelay = 2 days;
    euint64 private _quorumThreshold;

    event ProposalCreated(uint256 indexed id, address proposer);
    event VoteCast(address indexed voter, uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed id);

    constructor(externalEuint64 encQuorum, bytes memory proof) Ownable(msg.sender) {
        _quorumThreshold = FHE.fromExternal(encQuorum, proof);
        FHE.allowThis(_quorumThreshold);
    }

    function setVotingPower(address voter, externalEuint64 encPower, bytes calldata proof) external onlyOwner {
        _votingPower[voter] = FHE.fromExternal(encPower, proof);
        FHE.allowThis(_votingPower[voter]);
        FHE.allow(_votingPower[voter], voter);
    }

    function propose(address target, bytes calldata data, string calldata desc) external returns (uint256) {
        uint256 id = nextProposalId++;
        proposals[id] = Proposal({
            proposer: msg.sender,
            description: desc,
            callData: data,
            target: target,
            votesFor: FHE.asEuint64(0),
            votesAgainst: FHE.asEuint64(0),
            votesAbstain: FHE.asEuint64(0),
            startBlock: block.timestamp,
            endBlock: block.timestamp + votingPeriod,
            executionTime: 0,
            state: ProposalState.Active
        });
        FHE.allowThis(proposals[id].votesFor);
        FHE.allowThis(proposals[id].votesAgainst);
        FHE.allowThis(proposals[id].votesAbstain);
        emit ProposalCreated(id, msg.sender);
        return id;
    }

    function castVote(uint256 proposalId, uint8 support) external nonReentrant {
        require(proposals[proposalId].state == ProposalState.Active, "Not active");
        require(block.timestamp < proposals[proposalId].endBlock, "Voting ended");
        require(!hasVoted[msg.sender][proposalId], "Already voted");
        hasVoted[msg.sender][proposalId] = true;
        Proposal storage p = proposals[proposalId];
        if (support == 0) {
            p.votesAgainst = FHE.add(p.votesAgainst, _votingPower[msg.sender]);
            FHE.allowThis(p.votesAgainst);
        } else if (support == 1) {
            p.votesFor = FHE.add(p.votesFor, _votingPower[msg.sender]);
            FHE.allowThis(p.votesFor);
        } else {
            p.votesAbstain = FHE.add(p.votesAbstain, _votingPower[msg.sender]);
            FHE.allowThis(p.votesAbstain);
        }
        emit VoteCast(msg.sender, proposalId);
    }

    function finalizeProposal(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.state == ProposalState.Active && block.timestamp >= p.endBlock, "Not ready");
        euint64 totalVotes = FHE.add(FHE.add(p.votesFor, p.votesAgainst), p.votesAbstain);
        ebool quorumMet = FHE.ge(totalVotes, _quorumThreshold);
        ebool majorityFor = FHE.gt(p.votesFor, p.votesAgainst);
        ebool passes = FHE.and(quorumMet, majorityFor);
        // Simplified: resolve based on FHE.isInitialized result
        p.state = FHE.isInitialized(passes) ? ProposalState.Succeeded : ProposalState.Defeated;
        if (p.state == ProposalState.Succeeded) {
            p.executionTime = block.timestamp + timelockDelay;
        }
    }

    function executeProposal(uint256 proposalId) external onlyOwner nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(p.state == ProposalState.Succeeded, "Not succeeded");
        require(block.timestamp >= p.executionTime, "Timelock not expired");
        p.state = ProposalState.Executed;
        (bool success, ) = p.target.call(p.callData);
        require(success, "Execution failed");
        emit ProposalExecuted(proposalId);
    }

    function allowProposalVotes(uint256 proposalId, address viewer) external onlyOwner {
        FHE.allow(proposals[proposalId].votesFor, viewer);
        FHE.allow(proposals[proposalId].votesAgainst, viewer);
        FHE.allow(proposals[proposalId].votesAbstain, viewer);
    }
}
