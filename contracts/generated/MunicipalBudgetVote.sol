// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MunicipalBudgetVote - Encrypted voting for municipal budget allocation across departments
contract MunicipalBudgetVote is ZamaEthereumConfig, Ownable {
    enum Department { Roads, Healthcare, Education, Parks, Security }

    struct Proposal {
        string title;
        euint32[5] votes;
        uint256 startTime;
        uint256 endTime;
        bool finalized;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => bool) public registeredVoters;
    uint256 public proposalCount;

    event ProposalCreated(uint256 indexed proposalId, string title);
    event VoteCast(uint256 indexed proposalId, address indexed voter);
    event ProposalFinalized(uint256 indexed proposalId);

    constructor() Ownable(msg.sender) {}

    function registerVoter(address voter) external onlyOwner {
        registeredVoters[voter] = true;
    }

    function createProposal(string calldata title, uint256 duration) external onlyOwner returns (uint256 proposalId) {
        proposalId = proposalCount++;
        Proposal storage p = proposals[proposalId];
        p.title = title;
        p.startTime = block.timestamp;
        p.endTime = block.timestamp + duration;
        for (uint8 i = 0; i < 5; i++) {
            p.votes[i] = FHE.asEuint32(0);
            FHE.allowThis(p.votes[i]);
        }
        emit ProposalCreated(proposalId, title);
    }

    function castVote(
        uint256 proposalId,
        Department department,
        externalEuint32 calldata encWeight,
        bytes calldata inputProof
    ) external {
        require(registeredVoters[msg.sender], "Not registered");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        Proposal storage p = proposals[proposalId];
        require(block.timestamp >= p.startTime && block.timestamp <= p.endTime, "Not active");

        euint32 weight = FHE.fromExternal(encWeight, inputProof);
        uint8 deptIdx = uint8(department);
        p.votes[deptIdx] = FHE.add(p.votes[deptIdx], weight);
        FHE.allowThis(p.votes[deptIdx]);
        hasVoted[proposalId][msg.sender] = true;
        emit VoteCast(proposalId, msg.sender);
    }

    function finalizeProposal(uint256 proposalId) external onlyOwner {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp > p.endTime, "Still active");
        require(!p.finalized, "Already finalized");
        p.finalized = true;
        for (uint8 i = 0; i < 5; i++) {
            FHE.allow(p.votes[i], owner());
        }
        emit ProposalFinalized(proposalId);
    }
}
