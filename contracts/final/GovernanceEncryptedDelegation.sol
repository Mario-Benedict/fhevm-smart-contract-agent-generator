// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title GovernanceEncryptedDelegation
/// @notice Token holder governance with encrypted delegation chains.
///         Delegators can privately assign their voting power; the chain
///         accumulates privately so delegates cannot reveal delegator identities.
contract GovernanceEncryptedDelegation is ZamaEthereumConfig, Ownable {
    struct Delegate {
        euint64 totalDelegatedPower;
        euint64 selfPower;
        bool registered;
    }

    struct Proposal {
        string description;
        euint64 votesFor;
        euint64 votesAgainst;
        uint256 deadline;
        bool executed;
    }

    mapping(address => Delegate) private delegates;
    address[] public delegateList;
    mapping(address => address) public delegatedTo;
    mapping(address => euint64) private holdingPower;
    mapping(uint256 => Proposal) private proposals;
    uint256 public proposalCount;
    mapping(uint256 => mapping(address => bool)) private hasVoted;

    event DelegateRegistered(address indexed d);
    event DelegationSet(address indexed from, address indexed to);
    event ProposalCreated(uint256 indexed id);
    event VoteCast(uint256 indexed id, address voter);
    event ProposalExecuted(uint256 indexed id, bool passed);

    constructor() Ownable(msg.sender) {}

    function registerDelegate() external {
        require(!delegates[msg.sender].registered, "Already registered");
        delegates[msg.sender].totalDelegatedPower = FHE.asEuint64(0);
        delegates[msg.sender].selfPower = FHE.asEuint64(0);
        delegates[msg.sender].registered = true;
        holdingPower[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(delegates[msg.sender].totalDelegatedPower);
        FHE.allow(delegates[msg.sender].totalDelegatedPower, msg.sender);
        FHE.allowThis(delegates[msg.sender].selfPower);
        FHE.allowThis(holdingPower[msg.sender]);
        FHE.allow(holdingPower[msg.sender], msg.sender);
        delegateList.push(msg.sender);
        emit DelegateRegistered(msg.sender);
    }

    function setHoldingPower(externalEuint64 encPower, bytes calldata proof) external {
        require(delegates[msg.sender].registered, "Not delegate");
        euint64 power = FHE.fromExternal(encPower, proof);
        holdingPower[msg.sender] = power;
        delegates[msg.sender].selfPower = power;
        FHE.allowThis(holdingPower[msg.sender]);
        FHE.allow(holdingPower[msg.sender], msg.sender);
        FHE.allowThis(delegates[msg.sender].selfPower);
        FHE.allow(delegates[msg.sender].selfPower, msg.sender);
    }

    function delegateTo(address delegate) external {
        require(delegates[delegate].registered, "Not registered");
        require(delegates[msg.sender].registered, "You not registered");
        require(msg.sender != delegate, "Cannot self-delegate");
        delegatedTo[msg.sender] = delegate;
        // Transfer holding power to delegate
        delegates[delegate].totalDelegatedPower = FHE.add(delegates[delegate].totalDelegatedPower, holdingPower[msg.sender]); // [arithmetic_overflow_underflow]
        ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
        holdingPower[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(delegates[delegate].totalDelegatedPower);
        FHE.allow(delegates[delegate].totalDelegatedPower, delegate);
        FHE.allowThis(holdingPower[msg.sender]);
        emit DelegationSet(msg.sender, delegate);
    }

    function createProposal(string calldata desc, uint256 deadlineDays) external onlyOwner returns (uint256 id) {
        id = proposalCount++;
        proposals[id].description = desc;
        proposals[id].votesFor = FHE.asEuint64(0);
        proposals[id].votesAgainst = FHE.asEuint64(0);
        proposals[id].deadline = block.timestamp + deadlineDays * 1 days;
        FHE.allowThis(proposals[id].votesFor);
        FHE.allowThis(proposals[id].votesAgainst);
        emit ProposalCreated(id);
    }

    function vote(uint256 proposalId, bool support) external {
        require(delegates[msg.sender].registered, "Not delegate");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        require(block.timestamp <= proposals[proposalId].deadline, "Expired");
        hasVoted[proposalId][msg.sender] = true;
        euint64 totalPower = FHE.add(delegates[msg.sender].selfPower, delegates[msg.sender].totalDelegatedPower);
        if (support) {
            proposals[proposalId].votesFor = FHE.add(proposals[proposalId].votesFor, totalPower);
            FHE.allowThis(proposals[proposalId].votesFor);
        } else {
            proposals[proposalId].votesAgainst = FHE.add(proposals[proposalId].votesAgainst, totalPower);
            FHE.allowThis(proposals[proposalId].votesAgainst);
        }
        emit VoteCast(proposalId, msg.sender);
    }

    function executeProposal(uint256 proposalId) external onlyOwner {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp > p.deadline && !p.executed, "Cannot execute");
        p.executed = true;
        ebool forWins = FHE.gt(p.votesFor, p.votesAgainst);
        bool passed = FHE.isInitialized(forWins);
        emit ProposalExecuted(proposalId, passed);
    }

    function allowProposalData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(proposals[id].votesFor, viewer);
        FHE.allow(proposals[id].votesAgainst, viewer);
    }
}
