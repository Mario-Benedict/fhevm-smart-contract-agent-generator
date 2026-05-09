// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingCommunityLandTrust
/// @notice Community land trust governance where each member's land-value determines
///         their voting weight. Encrypted land valuations protect member privacy while
///         ensuring fair representation in land-use decisions.
contract VotingCommunityLandTrust is ZamaEthereumConfig, Ownable {
    struct LandHolder {
        euint64 landValueBps;   // encrypted land value weight
        bool registered;
        mapping(uint256 => bool) voted;
    }

    struct LandUseProposal {
        string description;
        string proposedUse;
        euint64 weightedApprove;
        euint64 weightedReject;
        uint256 deadline;
        bool approved;
        bool finalized;
    }

    mapping(address => LandHolder) private holders;
    address[] public holderList;
    mapping(uint256 => LandUseProposal) private proposals;
    uint256 public proposalCount;
    euint64 private _totalLandValue;

    event HolderRegistered(address indexed h);
    event ProposalCreated(uint256 indexed id, string description);
    event VoteCast(uint256 indexed id, address holder);
    event ProposalDecided(uint256 indexed id, bool approved);

    constructor() Ownable(msg.sender) {
        _totalLandValue = FHE.asEuint64(0);
        FHE.allowThis(_totalLandValue);
    }

    function registerHolder(address h, externalEuint64 encValue, bytes calldata proof) external onlyOwner {
        euint64 value = FHE.fromExternal(encValue, proof);
        holders[h].landValueBps = value;
        holders[h].registered = true;
        _totalLandValue = FHE.add(_totalLandValue, value);
        FHE.allowThis(holders[h].landValueBps);
        FHE.allow(holders[h].landValueBps, h);
        FHE.allowThis(_totalLandValue);
        holderList.push(h);
        emit HolderRegistered(h);
    }

    function createProposal(
        string calldata desc, string calldata use, uint256 daysOpen
    ) external onlyOwner returns (uint256 id) {
        id = proposalCount++;
        proposals[id].description = desc;
        proposals[id].proposedUse = use;
        proposals[id].weightedApprove = FHE.asEuint64(0);
        proposals[id].weightedReject = FHE.asEuint64(0);
        proposals[id].deadline = block.timestamp + daysOpen * 1 days;
        FHE.allowThis(proposals[id].weightedApprove);
        FHE.allowThis(proposals[id].weightedReject);
        emit ProposalCreated(id, desc);
    }

    function vote(uint256 proposalId, bool approve) external {
        LandHolder storage h = holders[msg.sender];
        require(h.registered, "Not holder");
        LandUseProposal storage p = proposals[proposalId];
        require(!p.finalized && block.timestamp <= p.deadline, "Closed");
        require(!h.voted[proposalId], "Already voted");
        h.voted[proposalId] = true;
        if (approve) {
            p.weightedApprove = FHE.add(p.weightedApprove, h.landValueBps);
            FHE.allowThis(p.weightedApprove);
        } else {
            p.weightedReject = FHE.add(p.weightedReject, h.landValueBps);
            FHE.allowThis(p.weightedReject);
        }
        emit VoteCast(proposalId, msg.sender);
    }

    function finalizeProposal(uint256 proposalId) external onlyOwner {
        LandUseProposal storage p = proposals[proposalId];
        require(!p.finalized, "Already finalized");
        p.finalized = true;
        ebool approved = FHE.gt(p.weightedApprove, p.weightedReject);
        p.approved = FHE.isInitialized(approved);
        emit ProposalDecided(proposalId, p.approved);
    }

    function allowProposalData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(proposals[id].weightedApprove, viewer);
        FHE.allow(proposals[id].weightedReject, viewer);
    }
}
