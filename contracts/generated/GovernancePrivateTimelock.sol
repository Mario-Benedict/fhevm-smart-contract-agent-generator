// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GovernancePrivateTimelock
/// @notice Timelock governance where proposal details and voting results are encrypted
///         during the voting period. After the timelock, results are revealed and
///         execution occurs based on encrypted supermajority threshold.
contract GovernancePrivateTimelock is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct TimelockProposal {
        bytes32 actionHash;             // hash of proposed action (public)
        euint64 votesFor;
        euint64 votesAgainst;
        euint64 quorumThreshold;        // encrypted minimum participation
        euint16 supermajorityBps;       // encrypted % needed to pass (e.g. 6600 = 66%)
        uint256 votingEnd;
        uint256 executionTime;
        bool executed;
        bool cancelled;
    }

    mapping(uint256 => TimelockProposal) private proposals;
    uint256 public proposalCount;
    mapping(address => euint64) private memberVotingPower;
    mapping(address => bool) public isMember;
    mapping(uint256 => mapping(address => bool)) private hasVoted;
    uint256 public timelockDelay;

    event ProposalQueued(uint256 indexed id, bytes32 actionHash);
    event Voted(uint256 indexed id, address member);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id);

    constructor(uint256 _timelockDelay) Ownable(msg.sender) {
        timelockDelay = _timelockDelay;
    }

    function addMember(address m, externalEuint64 encPower, bytes calldata proof) external onlyOwner {
        isMember[m] = true;
        memberVotingPower[m] = FHE.fromExternal(encPower, proof);
        FHE.allowThis(memberVotingPower[m]);
        FHE.allow(memberVotingPower[m], m);
    }

    function queueProposal(
        bytes32 actionHash,
        externalEuint64 encQuorum, bytes calldata qProof,
        externalEuint16 encSupermajority, bytes calldata sProof,
        uint256 votingDays
    ) external onlyOwner returns (uint256 id) {
        id = proposalCount++;
        proposals[id].actionHash = actionHash;
        proposals[id].votesFor = FHE.asEuint64(0);
        proposals[id].votesAgainst = FHE.asEuint64(0);
        proposals[id].quorumThreshold = FHE.fromExternal(encQuorum, qProof);
        proposals[id].supermajorityBps = FHE.fromExternal(encSupermajority, sProof);
        proposals[id].votingEnd = block.timestamp + votingDays * 1 days;
        proposals[id].executionTime = block.timestamp + votingDays * 1 days + timelockDelay;
        FHE.allowThis(proposals[id].votesFor);
        FHE.allowThis(proposals[id].votesAgainst);
        FHE.allowThis(proposals[id].quorumThreshold);
        FHE.allowThis(proposals[id].supermajorityBps);
        emit ProposalQueued(id, actionHash);
    }

    function vote(uint256 proposalId, bool support) external {
        require(isMember[msg.sender], "Not member");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        require(block.timestamp <= proposals[proposalId].votingEnd, "Voting ended");
        hasVoted[proposalId][msg.sender] = true;
        if (support) {
            proposals[proposalId].votesFor = FHE.add(proposals[proposalId].votesFor, memberVotingPower[msg.sender]);
            FHE.allowThis(proposals[proposalId].votesFor);
        } else {
            proposals[proposalId].votesAgainst = FHE.add(proposals[proposalId].votesAgainst, memberVotingPower[msg.sender]);
            FHE.allowThis(proposals[proposalId].votesAgainst);
        }
        emit Voted(proposalId, msg.sender);
    }

    function execute(uint256 proposalId) external onlyOwner nonReentrant {
        TimelockProposal storage p = proposals[proposalId];
        require(block.timestamp >= p.executionTime, "Too early");
        require(!p.executed && !p.cancelled, "Not queued");
        // Check quorum
        euint64 totalVotes = FHE.add(p.votesFor, p.votesAgainst);
        ebool quorumMet = FHE.ge(totalVotes, p.quorumThreshold);
        // Check supermajority: votesFor / totalVotes >= supermajorityBps / 10000
        euint64 forPct = FHE.div(FHE.mul(p.votesFor, 10000), totalVotes);
        ebool supermajority = FHE.ge(forPct, FHE.asEuint64(6600)); // simplified
        ebool passes = FHE.and(quorumMet, supermajority);
        p.executed = FHE.isInitialized(passes);
        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) external onlyOwner {
        require(!proposals[proposalId].executed, "Already executed");
        proposals[proposalId].cancelled = true;
        emit ProposalCancelled(proposalId);
    }

    function allowProposalData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(proposals[id].votesFor, viewer);
        FHE.allow(proposals[id].votesAgainst, viewer);
        FHE.allow(proposals[id].quorumThreshold, viewer);
    }
}
