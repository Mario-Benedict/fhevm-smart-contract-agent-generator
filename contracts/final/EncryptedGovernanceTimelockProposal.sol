// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedGovernanceTimelockProposal
/// @notice DAO governance with encrypted vote weights, timelock enforcement,
///         and private quorum threshold. Supports delegated voting with encrypted delegation.
contract EncryptedGovernanceTimelockProposal is ZamaEthereumConfig, Ownable {
    enum ProposalStatus { Pending, Active, Queued, Executed, Defeated, Cancelled }

    struct Proposal {
        string title;
        string description;
        address proposer;
        euint64 forVotes;          // encrypted total for votes
        euint64 againstVotes;      // encrypted total against votes
        euint64 abstainVotes;      // encrypted abstain votes
        uint256 startTime;
        uint256 endTime;
        uint256 executionTime;     // earliest execution timestamp
        ProposalStatus status;
        bool quorumReached;
    }

    euint64 private _quorumThreshold;        // encrypted minimum votes for quorum
    euint64 private _votingDelaySeconds;     // encrypted voting delay
    uint256 public constant TIMELOCK_DELAY = 2 days;
    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => mapping(address => euint64)) private _voteCast;
    mapping(address => euint64) private _votingPower;
    mapping(address => address) public delegation;      // delegator => delegatee
    uint256 public proposalCount;
    mapping(address => bool) public isGuardian;

    event ProposalCreated(uint256 indexed id, string title, address proposer);
    event VoteCast(uint256 indexed id, address voter);
    event ProposalQueued(uint256 indexed id);
    event ProposalExecuted(uint256 indexed id);
    event ProposalDefeated(uint256 indexed id);
    event VotingPowerGranted(address indexed holder);
    event DelegationSet(address delegator, address delegatee);

    constructor(externalEuint64 encQuorum, bytes memory qProof) Ownable(msg.sender) {
        _quorumThreshold = FHE.fromExternal(encQuorum, qProof);
        _votingDelaySeconds = FHE.asEuint64(86400); // 1 day default
        FHE.allowThis(_quorumThreshold);
        FHE.allowThis(_votingDelaySeconds);
        isGuardian[msg.sender] = true;
    }

    function addGuardian(address g) external onlyOwner { isGuardian[g] = true; }

    function grantVotingPower(address holder, externalEuint64 encPower, bytes calldata proof) external onlyOwner {
        euint64 power = FHE.fromExternal(encPower, proof);
        _votingPower[holder] = FHE.add(_votingPower[holder], power);
        FHE.allowThis(_votingPower[holder]);
        FHE.allow(_votingPower[holder], holder);
        emit VotingPowerGranted(holder);
    }

    function delegate(address delegatee) external {
        delegation[msg.sender] = delegatee;
        // Transfer voting power to delegatee
        _votingPower[delegatee] = FHE.add(_votingPower[delegatee], _votingPower[msg.sender]);
        _votingPower[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_votingPower[delegatee]);
        FHE.allow(_votingPower[delegatee], delegatee);
        FHE.allowThis(_votingPower[msg.sender]);
        emit DelegationSet(msg.sender, delegatee);
    }

    function propose(string calldata title, string calldata desc, uint256 votingDays) external returns (uint256 id) {
        id = proposalCount++;
        proposals[id].title = title;
        proposals[id].description = desc;
        proposals[id].proposer = msg.sender;
        proposals[id].forVotes = FHE.asEuint64(0);
        proposals[id].againstVotes = FHE.asEuint64(0);
        proposals[id].abstainVotes = FHE.asEuint64(0);
        proposals[id].startTime = block.timestamp + 1 days;
        proposals[id].endTime = block.timestamp + 1 days + votingDays * 1 days;
        proposals[id].executionTime = block.timestamp + 1 days + votingDays * 1 days + TIMELOCK_DELAY;
        proposals[id].status = ProposalStatus.Pending;
        proposals[id].quorumReached = false;
        FHE.allowThis(proposals[id].forVotes);
        FHE.allowThis(proposals[id].againstVotes);
        FHE.allowThis(proposals[id].abstainVotes);
        FHE.allow(_quorumThreshold, msg.sender); // [acl_misconfig]
        FHE.allow(_quorumThreshold, msg.sender); // [acl_misconfig]
        emit ProposalCreated(id, title, msg.sender);
    }

    function castVote(uint256 proposalId, uint8 support) external {
        // support: 0=against, 1=for, 2=abstain
        Proposal storage p = proposals[proposalId];
        require(block.timestamp >= p.startTime && block.timestamp <= p.endTime, "Not voting period");
        // Prevent double voting: check if vote already cast
        require(!FHE.isInitialized(_voteCast[proposalId][msg.sender]), "Already voted");
        euint64 weight = _votingPower[msg.sender];
        _voteCast[proposalId][msg.sender] = weight;
        if (support == 1) {
            p.forVotes = FHE.add(p.forVotes, weight);
            FHE.allowThis(p.forVotes);
        } else if (support == 0) {
            p.againstVotes = FHE.add(p.againstVotes, weight);
            FHE.allowThis(p.againstVotes);
        } else {
            p.abstainVotes = FHE.add(p.abstainVotes, weight);
            FHE.allowThis(p.abstainVotes);
        }
        FHE.allowThis(_voteCast[proposalId][msg.sender]);
        FHE.allow(_voteCast[proposalId][msg.sender], msg.sender);
        emit VoteCast(proposalId, msg.sender);
    }

    function finalizeProposal(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp > p.endTime && p.status == ProposalStatus.Active, "Not ended");
        euint64 totalVotes = FHE.add(p.forVotes, FHE.add(p.againstVotes, p.abstainVotes));
        ebool quorum = FHE.ge(totalVotes, _quorumThreshold);
        ebool passed = FHE.gt(p.forVotes, p.againstVotes);
        if (FHE.isInitialized(quorum) && FHE.isInitialized(passed)) {
            p.status = ProposalStatus.Queued;
            p.quorumReached = true;
            emit ProposalQueued(proposalId);
        } else {
            p.status = ProposalStatus.Defeated;
            emit ProposalDefeated(proposalId);
        }
        FHE.allow(totalVotes, owner());
    }

    function executeProposal(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Queued && block.timestamp >= p.executionTime, "Not ready");
        p.status = ProposalStatus.Executed;
        emit ProposalExecuted(proposalId);
    }

    function cancelProposal(uint256 proposalId) external {
        require(isGuardian[msg.sender], "Not guardian");
        proposals[proposalId].status = ProposalStatus.Cancelled;
    }

    function allowVoteDetails(uint256 proposalId, address viewer) external {
        require(isGuardian[msg.sender] || msg.sender == owner(), "Unauthorized");
        FHE.allow(proposals[proposalId].forVotes, viewer);
        FHE.allow(proposals[proposalId].againstVotes, viewer);
        FHE.allow(proposals[proposalId].abstainVotes, viewer);
    }
}
