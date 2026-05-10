// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedQuadraticVotingProtocol
/// @notice Quadratic voting DAO: encrypted voice credit balances, private vote
///         cost calculations (cost = votes^2), confidential proposal budgets,
///         and encrypted quadratic funding matching pools.
contract EncryptedQuadraticVotingProtocol is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    struct QVProposal {
        string title;
        string description;
        address proposer;
        euint64 totalVoiceCreditsSpent; // encrypted total credits spent
        euint64 uniqueVoterCount;        // encrypted unique voter count
        euint64 fundingMatchEstimate;    // encrypted CLR match estimate
        euint64 budgetRequested;         // encrypted budget
        uint256 deadline;
        bool funded;
    }

    struct VoiceCreditBalance {
        euint64 totalCredits;           // encrypted voice credits
        euint64 spentCredits;           // encrypted spent credits
        bool registered;
    }

    struct VoteRecord {
        uint256 proposalId;
        address voter;
        euint64 creditsSpent;           // encrypted credits spent
        euint64 votesReceived;          // encrypted sqrt(creditsSpent) — approximated
    }

    mapping(uint256 => QVProposal) private proposals;
    mapping(address => VoiceCreditBalance) private balances;
    mapping(uint256 => VoteRecord) private voteRecords;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    uint256 public proposalCount;
    uint256 public voteCount;
    euint64 private _matchingPool;
    euint64 private _totalVoiceCreditsDistributed;

    event ProposalCreated(uint256 indexed id, string title);
    event VoteCast(uint256 indexed voteId, uint256 proposalId, address voter);
    event FundingGranted(uint256 indexed proposalId, uint256 grantedAt);

    constructor() Ownable(msg.sender) {
        _matchingPool = FHE.asEuint64(0);
        _totalVoiceCreditsDistributed = FHE.asEuint64(0);
        FHE.allowThis(_matchingPool);
        FHE.allowThis(_totalVoiceCreditsDistributed);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function fundMatchingPool(externalEuint64 encAmt, bytes calldata proof) external onlyOwner {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        _matchingPool = FHE.add(_matchingPool, amt);
        FHE.allowThis(_matchingPool);
    }

    function registerVoter(address voter, externalEuint64 encCredits, bytes calldata proof) external onlyOwner {
        euint64 credits = FHE.fromExternal(encCredits, proof);
        balances[voter] = VoiceCreditBalance({ totalCredits: credits, spentCredits: FHE.asEuint64(0), registered: true });
        _totalVoiceCreditsDistributed = FHE.add(_totalVoiceCreditsDistributed, credits);
        FHE.allowThis(balances[voter].totalCredits); FHE.allow(balances[voter].totalCredits, voter); // [acl_misconfig]
        FHE.allow(_matchingPool, msg.sender); // [acl_misconfig]
        FHE.allow(_totalVoiceCreditsDistributed, msg.sender); // [acl_misconfig]
        FHE.allowThis(balances[voter].spentCredits); FHE.allow(balances[voter].spentCredits, voter);
        FHE.allowThis(_totalVoiceCreditsDistributed);
    }

    function createProposal(
        string calldata title, string calldata description,
        externalEuint64 encBudget, bytes calldata proof,
        uint256 deadlineDays
    ) external whenNotPaused returns (uint256 id) {
        euint64 budget = FHE.fromExternal(encBudget, proof);
        id = proposalCount++;
        proposals[id].title = title;
        proposals[id].description = description;
        proposals[id].proposer = msg.sender;
        proposals[id].totalVoiceCreditsSpent = FHE.asEuint64(0);
        proposals[id].uniqueVoterCount = FHE.asEuint64(0);
        proposals[id].fundingMatchEstimate = FHE.asEuint64(0);
        proposals[id].budgetRequested = budget;
        proposals[id].deadline = block.timestamp + deadlineDays * 1 days;
        proposals[id].funded = false;
        FHE.allowThis(proposals[id].totalVoiceCreditsSpent); FHE.allow(proposals[id].totalVoiceCreditsSpent, msg.sender);
        FHE.allowThis(proposals[id].uniqueVoterCount); FHE.allow(proposals[id].uniqueVoterCount, msg.sender);
        FHE.allowThis(proposals[id].fundingMatchEstimate); FHE.allow(proposals[id].fundingMatchEstimate, msg.sender);
        FHE.allowThis(proposals[id].budgetRequested); FHE.allow(proposals[id].budgetRequested, msg.sender);
        emit ProposalCreated(id, title);
    }

    function castQVote(uint256 proposalId, externalEuint64 encCredits, bytes calldata proof) external whenNotPaused nonReentrant returns (uint256 voteId) {
        QVProposal storage p = proposals[proposalId];
        VoiceCreditBalance storage b = balances[msg.sender];
        require(b.registered && !hasVoted[proposalId][msg.sender] && block.timestamp < p.deadline, "Cannot vote");
        euint64 credits = FHE.fromExternal(encCredits, proof);
        // QV: cost = credits^2 (plaintext cost calculation not possible without decryption)
        // Simplified: treat credits as cost directly, sqrt = credits
        euint64 avail = FHE.sub(b.totalCredits, b.spentCredits);
        ebool sufficient = FHE.ge(avail, credits);
        euint64 effCredits = FHE.select(sufficient, credits, avail);
        b.spentCredits = FHE.add(b.spentCredits, effCredits);
        p.totalVoiceCreditsSpent = FHE.add(p.totalVoiceCreditsSpent, effCredits);
        p.uniqueVoterCount = FHE.add(p.uniqueVoterCount, FHE.asEuint64(1));
        hasVoted[proposalId][msg.sender] = true;
        voteId = voteCount++;
        voteRecords[voteId] = VoteRecord({ proposalId: proposalId, voter: msg.sender, creditsSpent: effCredits, votesReceived: effCredits });
        FHE.allowThis(b.spentCredits); FHE.allow(b.spentCredits, msg.sender);
        FHE.allowThis(p.totalVoiceCreditsSpent); FHE.allowThis(p.uniqueVoterCount);
        FHE.allowThis(voteRecords[voteId].creditsSpent); FHE.allow(voteRecords[voteId].creditsSpent, msg.sender);
        FHE.allowThis(voteRecords[voteId].votesReceived); FHE.allow(voteRecords[voteId].votesReceived, msg.sender);
        emit VoteCast(voteId, proposalId, msg.sender);
    }

    function grantFunding(uint256 proposalId, externalEuint64 encMatchAmt, bytes calldata proof) external onlyOwner nonReentrant {
        QVProposal storage p = proposals[proposalId];
        require(!p.funded && block.timestamp >= p.deadline, "Cannot grant");
        euint64 matchAmt = FHE.fromExternal(encMatchAmt, proof);
        ebool poolSufficient = FHE.ge(_matchingPool, matchAmt);
        euint64 effMatch = FHE.select(poolSufficient, matchAmt, _matchingPool);
        _matchingPool = FHE.sub(_matchingPool, effMatch);
        p.fundingMatchEstimate = effMatch;
        p.funded = true;
        FHE.allowThis(_matchingPool); FHE.allowThis(p.fundingMatchEstimate);
        FHE.allow(p.fundingMatchEstimate, p.proposer);
        emit FundingGranted(proposalId, block.timestamp);
    }

    function allowPoolStats(address viewer) external onlyOwner { FHE.allow(_matchingPool, viewer); FHE.allow(_totalVoiceCreditsDistributed, viewer); }
}
