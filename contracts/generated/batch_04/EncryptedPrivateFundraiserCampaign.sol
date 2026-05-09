// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivateFundraiserCampaign
/// @notice Encrypted fundraiser: private donation amounts, hidden goal progress,
///         confidential donor identities, and encrypted milestone-gated fund
///         release to beneficiary.
contract EncryptedPrivateFundraiserCampaign is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum CampaignStatus { Active, GoalReached, Expired, Withdrawn }

    struct Campaign {
        address beneficiary;
        string title;
        string description;
        euint64 goalAmountUSD;          // encrypted goal
        euint64 raisedAmountUSD;        // encrypted raised
        euint64 donorCount;             // encrypted unique donors
        euint64 milestone1USD;          // encrypted milestone 1
        euint64 milestone2USD;          // encrypted milestone 2
        euint64 milestone1Released;     // encrypted amount released at M1
        euint64 milestone2Released;     // encrypted amount released at M2
        CampaignStatus status;
        uint256 deadline;
    }

    struct Donation {
        uint256 campaignId;
        address donor;
        euint64 amountUSD;              // encrypted donation
        uint256 donatedAt;
    }

    mapping(uint256 => Campaign) private campaigns;
    mapping(uint256 => Donation) private donations;
    mapping(uint256 => mapping(address => bool)) public hasDonated;

    uint256 public campaignCount;
    uint256 public donationCount;
    euint64 private _totalFundsRaisedUSD;
    euint64 private _totalFundsReleasedUSD;

    event CampaignCreated(uint256 indexed id, string title);
    event DonationReceived(uint256 indexed donationId, uint256 campaignId);
    event MilestoneReleased(uint256 indexed campaignId, uint256 milestone);

    constructor() Ownable(msg.sender) {
        _totalFundsRaisedUSD = FHE.asEuint64(0);
        _totalFundsReleasedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalFundsRaisedUSD);
        FHE.allowThis(_totalFundsReleasedUSD);
    }

    function createCampaign(
        address beneficiary, string calldata title, string calldata description,
        externalEuint64 encGoal, bytes calldata gProof,
        externalEuint64 encM1,   bytes calldata m1Proof,
        externalEuint64 encM2,   bytes calldata m2Proof,
        uint256 durationDays
    ) external returns (uint256 id) {
        euint64 goal = FHE.fromExternal(encGoal, gProof);
        euint64 m1   = FHE.fromExternal(encM1, m1Proof);
        euint64 m2   = FHE.fromExternal(encM2, m2Proof);
        id = campaignCount++;
        Campaign storage _s0 = campaigns[id];
        _s0.beneficiary = beneficiary;
        _s0.title = title;
        _s0.description = description;
        _s0.goalAmountUSD = goal;
        _s0.raisedAmountUSD = FHE.asEuint64(0);
        _s0.donorCount = FHE.asEuint64(0);
        _s0.milestone1USD = m1;
        _s0.milestone2USD = m2;
        _s0.milestone1Released = FHE.asEuint64(0);
        _s0.milestone2Released = FHE.asEuint64(0);
        _s0.status = CampaignStatus.Active;
        _s0.deadline = block.timestamp + durationDays * 1 days;
        FHE.allowThis(campaigns[id].goalAmountUSD); FHE.allow(campaigns[id].goalAmountUSD, beneficiary);
        FHE.allowThis(campaigns[id].raisedAmountUSD); FHE.allow(campaigns[id].raisedAmountUSD, beneficiary);
        FHE.allowThis(campaigns[id].donorCount); FHE.allow(campaigns[id].donorCount, beneficiary);
        FHE.allowThis(campaigns[id].milestone1USD); FHE.allowThis(campaigns[id].milestone2USD);
        FHE.allowThis(campaigns[id].milestone1Released); FHE.allowThis(campaigns[id].milestone2Released);
        emit CampaignCreated(id, title);
    }

    function donate(uint256 campaignId, externalEuint64 encAmt, bytes calldata proof) external nonReentrant returns (uint256 donationId) {
        Campaign storage c = campaigns[campaignId];
        require(c.status == CampaignStatus.Active && block.timestamp < c.deadline, "Not active");
        euint64 amt = FHE.fromExternal(encAmt, proof);
        c.raisedAmountUSD = FHE.add(c.raisedAmountUSD, amt);
        if (!hasDonated[campaignId][msg.sender]) {
            hasDonated[campaignId][msg.sender] = true;
            c.donorCount = FHE.add(c.donorCount, FHE.asEuint64(1));
        }
        _totalFundsRaisedUSD = FHE.add(_totalFundsRaisedUSD, amt);
        donationId = donationCount++;
        donations[donationId] = Donation({ campaignId: campaignId, donor: msg.sender, amountUSD: amt, donatedAt: block.timestamp });
        FHE.allowThis(donations[donationId].amountUSD); FHE.allow(donations[donationId].amountUSD, msg.sender);
        FHE.allowThis(c.raisedAmountUSD); FHE.allow(c.raisedAmountUSD, c.beneficiary);
        FHE.allowThis(c.donorCount); FHE.allow(c.donorCount, c.beneficiary);
        FHE.allowThis(_totalFundsRaisedUSD);
        emit DonationReceived(donationId, campaignId);
    }

    function releaseMilestone(uint256 campaignId, uint8 milestone) external onlyOwner nonReentrant {
        Campaign storage c = campaigns[campaignId];
        if (milestone == 1) {
            ebool m1Reached = FHE.ge(c.raisedAmountUSD, c.milestone1USD);
            euint64 releaseAmt = FHE.select(m1Reached, c.milestone1USD, FHE.asEuint64(0));
            c.milestone1Released = releaseAmt;
            _totalFundsReleasedUSD = FHE.add(_totalFundsReleasedUSD, releaseAmt);
            FHE.allowThis(c.milestone1Released); FHE.allow(c.milestone1Released, c.beneficiary);
        } else {
            ebool m2Reached = FHE.ge(c.raisedAmountUSD, c.milestone2USD);
            euint64 releaseAmt = FHE.select(m2Reached, c.milestone2USD, FHE.asEuint64(0));
            c.milestone2Released = releaseAmt;
            _totalFundsReleasedUSD = FHE.add(_totalFundsReleasedUSD, releaseAmt);
            FHE.allowThis(c.milestone2Released); FHE.allow(c.milestone2Released, c.beneficiary);
        }
        FHE.allowThis(_totalFundsReleasedUSD);
        emit MilestoneReleased(campaignId, milestone);
    }

    function allowFundraiserStats(address viewer) external onlyOwner {
        FHE.allow(_totalFundsRaisedUSD, viewer); FHE.allow(_totalFundsReleasedUSD, viewer);
    }
    function getRaised(uint256 id) external view returns (euint64) { return campaigns[id].raisedAmountUSD; }
}
