// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCrowdfundingVault - Private crowdfunding with hidden contribution amounts
contract EncryptedCrowdfundingVault is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Campaign {
        address creator;
        string title;
        string description;
        euint64 goalAmount;
        euint64 raisedAmount;
        uint256 deadline;
        bool finalized;
        bool goalReached;
        uint256 contributorCount;
    }

    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => mapping(address => euint64)) private contributions;
    mapping(uint256 => mapping(address => bool)) public hasContributed;
    uint256 public campaignCount;

    event CampaignLaunched(uint256 indexed campaignId, address indexed creator, string title);
    event ContributionMade(uint256 indexed campaignId, address indexed contributor);
    event CampaignFinalized(uint256 indexed campaignId, bool goalReached);
    event RefundIssued(uint256 indexed campaignId, address indexed contributor);

    constructor() Ownable(msg.sender) {}

    function launchCampaign(
        string calldata title,
        string calldata description,
        uint256 durationDays,
        externalEuint64 encGoal,
        bytes calldata inputProof
    ) external returns (uint256 campaignId) {
        campaignId = campaignCount++;
        Campaign storage c = campaigns[campaignId];
        c.creator = msg.sender;
        c.title = title;
        c.description = description;
        c.goalAmount = FHE.fromExternal(encGoal, inputProof);
        c.raisedAmount = FHE.asEuint64(0);
        c.deadline = block.timestamp + durationDays * 1 days;
        FHE.allowThis(c.goalAmount);
        FHE.allowThis(c.raisedAmount);
        FHE.allow(c.goalAmount, msg.sender);
        emit CampaignLaunched(campaignId, msg.sender, title);
    }

    function contribute(uint256 campaignId, externalEuint64 encAmount, bytes calldata inputProof)
        external
        nonReentrant
    {
        Campaign storage c = campaigns[campaignId];
        require(block.timestamp <= c.deadline, "Campaign ended");
        require(!c.finalized, "Finalized");

        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        contributions[campaignId][msg.sender] = FHE.add(contributions[campaignId][msg.sender], amount);
        c.raisedAmount = FHE.add(c.raisedAmount, amount);

        FHE.allowThis(contributions[campaignId][msg.sender]);
        FHE.allowThis(c.raisedAmount);
        FHE.allow(contributions[campaignId][msg.sender], msg.sender);
        FHE.allow(c.raisedAmount, c.creator);

        if (!hasContributed[campaignId][msg.sender]) {
            hasContributed[campaignId][msg.sender] = true;
            c.contributorCount++;
        }
        emit ContributionMade(campaignId, msg.sender);
    }

    function finalizeCampaign(uint256 campaignId, bool goalReached) external nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(block.timestamp > c.deadline, "Not ended");
        require(!c.finalized, "Done");
        require(msg.sender == c.creator || msg.sender == owner(), "Unauthorized");
        c.finalized = true;
        c.goalReached = goalReached;
        ebool reached = FHE.ge(c.raisedAmount, c.goalAmount);
        FHE.allowThis(reached);
        FHE.allow(c.raisedAmount, c.creator);
        FHE.allow(reached, c.creator);
        emit CampaignFinalized(campaignId, c.goalReached);
    }

    function claimRefund(uint256 campaignId) external nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(c.finalized && !c.goalReached, "Not refundable");
        euint64 refund = contributions[campaignId][msg.sender];
        contributions[campaignId][msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(contributions[campaignId][msg.sender]);
        FHE.allowTransient(refund, msg.sender);
        emit RefundIssued(campaignId, msg.sender);
    }

    function getContribution(uint256 campaignId) external view returns (euint64) {
        return contributions[campaignId][msg.sender];
    }
}
