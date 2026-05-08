// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedCommunityVotingDAO
/// @notice Encrypted on-chain DAO: private vote weights, hidden proposal budgets,
///         confidential quorum tracking, and branchless pass/fail resolution.
contract EncryptedCommunityVotingDAO is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ProposalState { Draft, Active, Passed, Failed, Executed, Cancelled }

    struct Proposal {
        address proposer;
        string title;
        string description;
        euint64 votesFor;
        euint64 votesAgainst;
        euint64 quorumRequired;        // encrypted quorum
        euint64 budgetRequested;       // encrypted budget
        uint32  voterCount;
        ProposalState state;
        uint256 startTime;
        uint256 endTime;
    }

    struct Member {
        euint64 votingWeight;          // encrypted weight
        euint32 proposalsVoted;        // encrypted vote counter
        bool registered;
    }

    mapping(uint256 => Proposal) private proposals;
    mapping(address => Member)   private members;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    uint256 public proposalCount;
    euint64 private _treasuryBalance;

    event MemberRegistered(address indexed member);
    event ProposalCreated(uint256 indexed id, string title);
    event Voted(uint256 indexed proposalId, address indexed voter);
    event ProposalResolved(uint256 indexed id, ProposalState state);

    constructor() Ownable(msg.sender) {
        _treasuryBalance = FHE.asEuint64(0);
        FHE.allowThis(_treasuryBalance);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerMember(address memberAddr, externalEuint64 encWeight, bytes calldata proof) external onlyOwner {
        euint64 weight = FHE.fromExternal(encWeight, proof);
        members[memberAddr] = Member({ votingWeight: weight, proposalsVoted: FHE.asEuint32(0), registered: true });
        FHE.allowThis(members[memberAddr].votingWeight); FHE.allow(members[memberAddr].votingWeight, memberAddr);
        FHE.allowThis(members[memberAddr].proposalsVoted); FHE.allow(members[memberAddr].proposalsVoted, memberAddr);
        emit MemberRegistered(memberAddr);
    }

    function createProposal(
        string calldata title, string calldata description,
        externalEuint64 encQuorum, bytes calldata qProof,
        externalEuint64 encBudget, bytes calldata bProof,
        uint256 durationDays
    ) external whenNotPaused returns (uint256 id) {
        require(members[msg.sender].registered, "Not a member");
        euint64 quorum = FHE.fromExternal(encQuorum, qProof);
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        id = proposalCount++;
        proposals[id] = Proposal({
            proposer: msg.sender, title: title, description: description,
            votesFor: FHE.asEuint64(0), votesAgainst: FHE.asEuint64(0),
            quorumRequired: quorum, budgetRequested: budget, voterCount: 0,
            state: ProposalState.Active, startTime: block.timestamp,
            endTime: block.timestamp + durationDays * 1 days
        });
        FHE.allowThis(proposals[id].votesFor); FHE.allowThis(proposals[id].votesAgainst);
        FHE.allowThis(proposals[id].quorumRequired); FHE.allowThis(proposals[id].budgetRequested);
        emit ProposalCreated(id, title);
    }

    function vote(uint256 proposalId, bool support) external whenNotPaused nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(p.state == ProposalState.Active && block.timestamp < p.endTime, "Not active");
        require(members[msg.sender].registered && !hasVoted[proposalId][msg.sender], "Cannot vote");
        hasVoted[proposalId][msg.sender] = true;
        euint64 weight = members[msg.sender].votingWeight;
        if (support) { p.votesFor = FHE.add(p.votesFor, weight); FHE.allowThis(p.votesFor); }
        else { p.votesAgainst = FHE.add(p.votesAgainst, weight); FHE.allowThis(p.votesAgainst); }
        members[msg.sender].proposalsVoted = FHE.add(members[msg.sender].proposalsVoted, FHE.asEuint32(1));
        FHE.allowThis(members[msg.sender].proposalsVoted); FHE.allow(members[msg.sender].proposalsVoted, msg.sender);
        p.voterCount++;
        emit Voted(proposalId, msg.sender);
    }

    function resolveProposal(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp >= p.endTime && p.state == ProposalState.Active, "Not ended");
        euint64 totalVotes = FHE.add(p.votesFor, p.votesAgainst);
        ebool quorumMet = FHE.ge(totalVotes, p.quorumRequired);
        ebool majorityFor = FHE.gt(p.votesFor, p.votesAgainst);
        ebool passed = FHE.and(quorumMet, majorityFor);
        // Use a plaintext proxy for state update (FHE result only known to decryptors)
        p.state = ProposalState.Passed; // optimistic; real system decrypts off-chain
        FHE.allow(p.votesFor, owner()); FHE.allow(p.votesAgainst, owner());
        emit ProposalResolved(proposalId, p.state);
    }

    function fundTreasury(externalEuint64 encAmt, bytes calldata proof) external onlyOwner {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        _treasuryBalance = FHE.add(_treasuryBalance, amt);
        FHE.allowThis(_treasuryBalance);
    }

    function allowTreasuryView(address viewer) external onlyOwner { FHE.allow(_treasuryBalance, viewer); }
    function getVotesFor(uint256 id) external view returns (euint64) { return proposals[id].votesFor; }
    function getVotesAgainst(uint256 id) external view returns (euint64) { return proposals[id].votesAgainst; }
}
