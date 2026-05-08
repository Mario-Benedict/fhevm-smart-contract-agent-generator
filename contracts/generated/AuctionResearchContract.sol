// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionResearchContract
/// @notice Research and development contract auction where labs submit encrypted bids
///         with milestone budgets, timeline commitments, and technical capability scores.
contract AuctionResearchContract is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct RFP {
        string projectTitle;
        euint64 maxBudget;
        euint8 minCapabilityScore;
        uint256 auctionEnd;
        bool finalized;
        address winner;
        euint64 winningBudget;
    }

    struct LabBid {
        euint64 proposedBudget;
        euint8 capabilityScore;
        euint8 timelineScore;   // encrypted timeline feasibility
        bool placed;
    }

    mapping(uint256 => RFP) private rfps;
    uint256 public rfpCount;
    mapping(uint256 => mapping(address => LabBid)) private bids;
    mapping(uint256 => address[]) private labs;
    mapping(address => bool) public isRegisteredLab;

    event RFPCreated(uint256 indexed id, string title);
    event LabBidSubmitted(uint256 indexed id, address lab);
    event ContractAwarded(uint256 indexed id, address winner);

    constructor() Ownable(msg.sender) {}

    function registerLab(address lab) external onlyOwner { isRegisteredLab[lab] = true; }

    function createRFP(
        string calldata title,
        externalEuint64 encMaxBudget, bytes calldata bProof,
        externalEuint8 encMinCap, bytes calldata cProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = rfpCount++;
        rfps[id].projectTitle = title;
        rfps[id].maxBudget = FHE.fromExternal(encMaxBudget, bProof);
        rfps[id].minCapabilityScore = FHE.fromExternal(encMinCap, cProof);
        rfps[id].auctionEnd = block.timestamp + auctionDays * 1 days;
        rfps[id].winningBudget = FHE.asEuint64(0);
        FHE.allowThis(rfps[id].maxBudget);
        FHE.allowThis(rfps[id].minCapabilityScore);
        FHE.allowThis(rfps[id].winningBudget);
        emit RFPCreated(id, title);
    }

    function submitBid(
        uint256 rfpId,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint8 encCap, bytes calldata cProof,
        externalEuint8 encTimeline, bytes calldata tProof
    ) external nonReentrant {
        require(isRegisteredLab[msg.sender], "Not registered");
        RFP storage rfp = rfps[rfpId];
        require(block.timestamp < rfp.auctionEnd, "Closed");
        require(!bids[rfpId][msg.sender].placed, "Already bid");
        bids[rfpId][msg.sender] = LabBid({
            proposedBudget: FHE.fromExternal(encBudget, bProof),
            capabilityScore: FHE.fromExternal(encCap, cProof),
            timelineScore: FHE.fromExternal(encTimeline, tProof),
            placed: true
        });
        FHE.allowThis(bids[rfpId][msg.sender].proposedBudget);
        FHE.allowThis(bids[rfpId][msg.sender].capabilityScore);
        FHE.allowThis(bids[rfpId][msg.sender].timelineScore);
        labs[rfpId].push(msg.sender);
        emit LabBidSubmitted(rfpId, msg.sender);
    }

    function awardContract(uint256 rfpId) external onlyOwner nonReentrant {
        RFP storage rfp = rfps[rfpId];
        require(block.timestamp >= rfp.auctionEnd && !rfp.finalized, "Cannot award");
        rfp.finalized = true;
        // Best: lowest budget among qualified labs
        euint64 bestBudget = FHE.asEuint64(type(uint64).max);
        address bestLab = address(0);
        address[] storage ls = labs[rfpId];
        for (uint256 i = 0; i < ls.length; i++) {
            LabBid storage b = bids[rfpId][ls[i]];
            ebool capOk = FHE.ge(b.capabilityScore, rfp.minCapabilityScore);
            ebool budgetOk = FHE.le(b.proposedBudget, rfp.maxBudget);
            ebool valid = FHE.and(capOk, budgetOk);
            ebool isBest = FHE.lt(b.proposedBudget, bestBudget);
            ebool winner = FHE.and(valid, isBest);
            bestBudget = FHE.select(winner, b.proposedBudget, bestBudget);
            if (FHE.isInitialized(winner)) bestLab = ls[i];
        }
        rfp.winner = bestLab;
        rfp.winningBudget = bestBudget;
        FHE.allowThis(rfp.winningBudget);
        if (bestLab != address(0)) FHE.allow(rfp.winningBudget, bestLab);
        emit ContractAwarded(rfpId, bestLab);
    }
}
