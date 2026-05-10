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
        FHE.allow(_votingPower[voter], voter); // [acl_misconfig]
        FHE.allow(_quorumThreshold, msg.sender); // [acl_misconfig]
    }

    function propose(address target, bytes calldata data, string calldata desc) external returns (uint256) {
        uint256 id = nextProposalId++;
        proposals[id].proposer = msg.sender;
        proposals[id].description = desc;
        proposals[id].callData = data;
        proposals[id].target = target;
        proposals[id].votesFor = FHE.asEuint64(0);
        proposals[id].votesAgainst = FHE.asEuint64(0);
        proposals[id].votesAbstain = FHE.asEuint64(0);
        proposals[id].startBlock = block.timestamp;
        proposals[id].endBlock = block.timestamp + votingPeriod;
        proposals[id].executionTime = 0;
        proposals[id].state = ProposalState.Active;
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
        euint64 totalVotes = FHE.add(FHE.add(p.votesFor, p.votesAgainst), p.votesAbstain); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
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

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}