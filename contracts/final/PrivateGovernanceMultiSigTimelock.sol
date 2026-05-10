// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateGovernanceMultiSigTimelock
/// @notice DAO governance with encrypted vote weights, proposal thresholds,
///         and multi-sig approval behind a timelock. Vote tallies hidden until reveal.
contract PrivateGovernanceMultiSigTimelock is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN");

    enum ProposalState { PENDING, ACTIVE, SUCCEEDED, DEFEATED, QUEUED, EXECUTED, CANCELLED }

    struct Proposal {
        string description;
        address target;
        bytes   callData;
        euint64 votesFor;             // encrypted yes tally
        euint64 votesAgainst;         // encrypted no tally
        euint64 votesAbstain;         // encrypted abstain tally
        euint64 quorumRequired;       // encrypted quorum threshold
        uint256 startBlock;
        uint256 endBlock;
        uint256 executionEta;         // timelock delay
        ProposalState state;
    }

    struct VoterRecord {
        euint64 votingPower;          // encrypted delegated power
        euint64 delegatedFrom;        // encrypted total delegated to this voter
        bool hasVoted;
    }

    mapping(uint256 => Proposal)                        private proposals;
    mapping(uint256 => mapping(address => VoterRecord)) private voterRecords;
    mapping(address => bool)                            private guardianSigned;
    uint256 public proposalCount;
    uint256 public timelockDelay = 2 days;
    euint64 private _totalVotingPower;
    euint64 private _proposalThreshold;   // encrypted minimum to propose
    uint256 public  guardianThreshold = 2; // multi-sig: need 2 guardians

    event ProposalCreated(uint256 indexed id, address proposer);
    event VoteCast(uint256 indexed id, address voter);
    event ProposalQueued(uint256 indexed id, uint256 eta);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id);

    constructor(
        externalEuint64 encThreshold, bytes memory proof
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PROPOSER_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);

        _proposalThreshold = FHE.fromExternal(encThreshold, proof);
        _totalVotingPower  = FHE.asEuint64(0);
        FHE.allowThis(_proposalThreshold);
        FHE.allowThis(_totalVotingPower);
    }

    function grantVotingPower(
        address voter,
        externalEuint64 encPower, bytes calldata proof
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        euint64 power = FHE.fromExternal(encPower, proof);
        euint64 powerWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 powerExposure = FHE.sub(powerWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        if (!FHE.isInitialized(voterRecords[0][voter].votingPower)) {
            voterRecords[0][voter].votingPower  = FHE.asEuint64(0);
            voterRecords[0][voter].delegatedFrom = FHE.asEuint64(0);
            FHE.allowThis(voterRecords[0][voter].votingPower);
            FHE.allowThis(voterRecords[0][voter].delegatedFrom);
        }
        voterRecords[0][voter].votingPower = FHE.add(
            voterRecords[0][voter].votingPower, power
        );
        _totalVotingPower = FHE.add(_totalVotingPower, power);
        FHE.allowThis(voterRecords[0][voter].votingPower);
        FHE.allow(voterRecords[0][voter].votingPower, voter); // [acl_misconfig]
        FHE.allow(_totalVotingPower, msg.sender); // [acl_misconfig]
        FHE.allow(_proposalThreshold, msg.sender); // [acl_misconfig]
        FHE.allowThis(_totalVotingPower);
        FHE.allow(_totalVotingPower, msg.sender);
    }

    function propose(
        string calldata description,
        address target,
        bytes calldata callData,
        externalEuint64 encQuorum, bytes calldata proof,
        uint256 votingPeriodBlocks
    ) external onlyRole(PROPOSER_ROLE) returns (uint256 propId) {
        euint64 quorum = FHE.fromExternal(encQuorum, proof);
        propId = proposalCount++;
        proposals[propId].description = description;
        proposals[propId].target = target;
        proposals[propId].callData = callData;
        proposals[propId].votesFor = FHE.asEuint64(0);
        proposals[propId].votesAgainst = FHE.asEuint64(0);
        proposals[propId].votesAbstain = FHE.asEuint64(0);
        proposals[propId].quorumRequired = quorum;
        proposals[propId].startBlock = block.number + 1;
        proposals[propId].endBlock = block.number + 1 + votingPeriodBlocks;
        proposals[propId].executionEta = 0;
        proposals[propId].state = ProposalState.ACTIVE;
        FHE.allowThis(proposals[propId].votesFor);
        FHE.allowThis(proposals[propId].votesAgainst);
        FHE.allowThis(proposals[propId].votesAbstain);
        FHE.allowThis(proposals[propId].quorumRequired);
        emit ProposalCreated(propId, msg.sender);
    }

    // 0 = For, 1 = Against, 2 = Abstain
    function castVote(uint256 propId, uint8 support) external nonReentrant {
        require(proposals[propId].state == ProposalState.ACTIVE, "Not active");
        require(block.number <= proposals[propId].endBlock, "Voting ended");
        require(!voterRecords[propId][msg.sender].hasVoted, "Already voted");
        require(FHE.isInitialized(voterRecords[0][msg.sender].votingPower), "No power");

        voterRecords[propId][msg.sender].hasVoted = true;
        euint64 power = voterRecords[0][msg.sender].votingPower;

        if (support == 0) {
            proposals[propId].votesFor = FHE.add(proposals[propId].votesFor, power);
            FHE.allowThis(proposals[propId].votesFor);
        } else if (support == 1) {
            proposals[propId].votesAgainst = FHE.add(proposals[propId].votesAgainst, power);
            FHE.allowThis(proposals[propId].votesAgainst);
        } else {
            proposals[propId].votesAbstain = FHE.add(proposals[propId].votesAbstain, power);
            FHE.allowThis(proposals[propId].votesAbstain);
        }
        emit VoteCast(propId, msg.sender);
    }

    function queueProposal(uint256 propId) external onlyRole(GUARDIAN_ROLE) {
        require(proposals[propId].state == ProposalState.ACTIVE, "Not active");
        require(block.number > proposals[propId].endBlock, "Still voting");

        // Check quorum: votesFor must exceed quorumRequired
        ebool quorumMet = FHE.ge(proposals[propId].votesFor, proposals[propId].quorumRequired);
        ebool moreFor   = FHE.gt(proposals[propId].votesFor, proposals[propId].votesAgainst);

        proposals[propId].state      = ProposalState.QUEUED;
        proposals[propId].executionEta = block.timestamp + timelockDelay;

        emit ProposalQueued(propId, proposals[propId].executionEta);
    }

    function executeProposal(uint256 propId) external payable nonReentrant {
        Proposal storage prop = proposals[propId];
        require(prop.state == ProposalState.QUEUED, "Not queued");
        require(block.timestamp >= prop.executionEta, "Timelock active");
        prop.state = ProposalState.EXECUTED;
        (bool ok, ) = prop.target.call{value: msg.value}(prop.callData);
        require(ok, "Execution failed");
        emit ProposalExecuted(propId);
    }

    function cancelProposal(uint256 propId) external onlyRole(GUARDIAN_ROLE) {
        proposals[propId].state = ProposalState.CANCELLED;
        emit ProposalCancelled(propId);
    }

    function allowVoteView(uint256 propId, address viewer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        FHE.allow(proposals[propId].votesFor, viewer);
        FHE.allow(proposals[propId].votesAgainst, viewer);
        FHE.allow(proposals[propId].votesAbstain, viewer);
    }
}
