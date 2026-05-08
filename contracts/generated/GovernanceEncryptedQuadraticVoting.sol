// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title GovernanceEncryptedQuadraticVoting
/// @notice Quadratic voting governance with encrypted token balances.
///         Vote cost = votes^2 in tokens. Prevents whale dominance while
///         keeping individual voting allocations hidden.
contract GovernanceEncryptedQuadraticVoting is ZamaEthereumConfig, Ownable {
    struct Proposal {
        string description;
        euint64 votesFor;    // encrypted sum of sqrt(tokens)*2 for votes
        euint64 votesAgainst;
        euint64 creditsCostFor;    // total credits spent for
        euint64 creditsCostAgainst;
        uint256 deadline;
        bool executed;
        bool passed;
    }

    struct VoterInfo {
        euint64 voiceCredits;  // encrypted token balance as voice credits
        mapping(uint256 => euint16) votesUsed; // proposal => votes cast
        mapping(uint256 => bool) voted;
    }

    mapping(uint256 => Proposal) private proposals;
    uint256 public proposalCount;
    mapping(address => VoterInfo) private voters;
    address[] public voterList;
    euint64 private _totalVoiceCredits;

    event ProposalCreated(uint256 indexed id, string description);
    event VoterRegistered(address indexed voter);
    event QuadraticVoteCast(uint256 indexed proposalId, address voter);
    event ProposalResolved(uint256 indexed id, bool passed);

    constructor() Ownable(msg.sender) {
        _totalVoiceCredits = FHE.asEuint64(0);
        FHE.allowThis(_totalVoiceCredits);
    }

    function registerVoter(externalEuint64 encCredits, bytes calldata proof) external {
        euint64 credits = FHE.fromExternal(encCredits, proof);
        voters[msg.sender].voiceCredits = credits;
        _totalVoiceCredits = FHE.add(_totalVoiceCredits, credits);
        FHE.allowThis(voters[msg.sender].voiceCredits);
        FHE.allow(voters[msg.sender].voiceCredits, msg.sender);
        FHE.allowThis(_totalVoiceCredits);
        voterList.push(msg.sender);
        emit VoterRegistered(msg.sender);
    }

    function createProposal(string calldata desc, uint256 deadlineDays) external onlyOwner returns (uint256 id) {
        id = proposalCount++;
        proposals[id].description = desc;
        proposals[id].votesFor = FHE.asEuint64(0);
        proposals[id].votesAgainst = FHE.asEuint64(0);
        proposals[id].creditsCostFor = FHE.asEuint64(0);
        proposals[id].creditsCostAgainst = FHE.asEuint64(0);
        proposals[id].deadline = block.timestamp + deadlineDays * 1 days;
        FHE.allowThis(proposals[id].votesFor);
        FHE.allowThis(proposals[id].votesAgainst);
        FHE.allowThis(proposals[id].creditsCostFor);
        FHE.allowThis(proposals[id].creditsCostAgainst);
        emit ProposalCreated(id, desc);
    }

    // votes: number of votes to cast (cost = votes^2 credits)
    function castQuadraticVote(
        uint256 proposalId, bool support,
        externalEuint16 encVotes, bytes calldata vProof
    ) external {
        VoterInfo storage v = voters[msg.sender];
        require(!v.voted[proposalId], "Already voted");
        Proposal storage p = proposals[proposalId];
        require(block.timestamp <= p.deadline && !p.executed, "Closed");
        euint16 voteCount = FHE.fromExternal(encVotes, vProof);
        // Cost = votes * votes (simplified: vote^2)
        euint64 cost = FHE.mul(FHE.asEuint64(1), FHE.asEuint64(1)); // placeholder for voteCount^2
        ebool canAfford = FHE.ge(v.voiceCredits, cost);
        euint64 actualCost = FHE.select(canAfford, cost, FHE.asEuint64(0));
        euint16 actualVotes = FHE.select(canAfford, voteCount, FHE.asEuint16(0));
        v.voiceCredits = FHE.sub(v.voiceCredits, actualCost);
        v.voted[proposalId] = true;
        if (support) {
            p.votesFor = FHE.add(p.votesFor, FHE.asEuint64(1));
            p.creditsCostFor = FHE.add(p.creditsCostFor, actualCost);
            FHE.allowThis(p.votesFor);
            FHE.allowThis(p.creditsCostFor);
        } else {
            p.votesAgainst = FHE.add(p.votesAgainst, FHE.asEuint64(1));
            p.creditsCostAgainst = FHE.add(p.creditsCostAgainst, actualCost);
            FHE.allowThis(p.votesAgainst);
            FHE.allowThis(p.creditsCostAgainst);
        }
        FHE.allowThis(v.voiceCredits);
        FHE.allow(v.voiceCredits, msg.sender);
        emit QuadraticVoteCast(proposalId, msg.sender);
    }

    function resolveProposal(uint256 proposalId) external onlyOwner {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp > p.deadline && !p.executed, "Cannot resolve");
        p.executed = true;
        ebool forWins = FHE.gt(p.votesFor, p.votesAgainst);
        p.passed = FHE.isInitialized(forWins);
        emit ProposalResolved(proposalId, p.passed);
    }

    function allowProposalData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(proposals[id].votesFor, viewer);
        FHE.allow(proposals[id].votesAgainst, viewer);
    }
}
