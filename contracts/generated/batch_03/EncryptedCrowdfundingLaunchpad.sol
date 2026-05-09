// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCrowdfundingLaunchpad
/// @notice Privacy-preserving crowdfunding: encrypted fundraising target, encrypted individual
///         contributions, and encrypted soft cap/hard cap enforcement.
contract EncryptedCrowdfundingLaunchpad is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum CampaignStatus { Active, SoftCapReached, HardCapReached, Failed, Refunding, Closed }

    struct Campaign {
        string projectName;
        string description;
        address creator;
        euint64 softCap;          // encrypted minimum to succeed
        euint64 hardCap;          // encrypted maximum to collect
        euint64 totalRaised;      // encrypted total committed
        euint64 platformFeeBps;   // encrypted platform fee
        uint256 deadline;
        CampaignStatus status;
        bool claimedByCreator;
    }

    mapping(uint256 => Campaign) private campaigns;
    mapping(uint256 => mapping(address => euint64)) private _contributions;
    mapping(uint256 => mapping(address => bool)) private _hasContributed;
    mapping(address => euint64) private _refundBalance;
    uint256 public campaignCount;
    euint64 private _totalPlatformFees;
    address public platformTreasury;

    event CampaignCreated(uint256 indexed id, string name, address creator);
    event ContributionMade(uint256 indexed campaignId, address contributor);
    event CampaignSucceeded(uint256 indexed id, bool hardCapHit);
    event CampaignFailed(uint256 indexed id);
    event RefundIssued(uint256 indexed campaignId, address contributor);
    event FundsWithdrawn(uint256 indexed id, address creator);

    constructor(address treasury) Ownable(msg.sender) {
        platformTreasury = treasury;
        _totalPlatformFees = FHE.asEuint64(0);
        FHE.allowThis(_totalPlatformFees);
    }

    function createCampaign(
        string calldata name, string calldata description,
        externalEuint64 encSoftCap, bytes calldata scProof,
        externalEuint64 encHardCap, bytes calldata hcProof,
        externalEuint64 encPlatformFee, bytes calldata pfProof,
        uint256 durationDays
    ) external returns (uint256 id) {
        euint64 softCap = FHE.fromExternal(encSoftCap, scProof);
        euint64 hardCap = FHE.fromExternal(encHardCap, hcProof);
        euint64 platFee = FHE.fromExternal(encPlatformFee, pfProof);
        id = campaignCount++;
        campaigns[id].projectName = name;
        campaigns[id].description = description;
        campaigns[id].creator = msg.sender;
        campaigns[id].softCap = softCap;
        campaigns[id].hardCap = hardCap;
        campaigns[id].totalRaised = FHE.asEuint64(0);
        campaigns[id].platformFeeBps = platFee;
        campaigns[id].deadline = block.timestamp + durationDays * 1 days;
        campaigns[id].status = CampaignStatus.Active;
        campaigns[id].claimedByCreator = false;
        FHE.allowThis(campaigns[id].softCap);
        FHE.allow(campaigns[id].softCap, msg.sender);
        FHE.allowThis(campaigns[id].hardCap);
        FHE.allow(campaigns[id].hardCap, msg.sender);
        FHE.allowThis(campaigns[id].totalRaised);
        FHE.allowThis(campaigns[id].platformFeeBps);
        emit CampaignCreated(id, name, msg.sender);
    }

    function contribute(uint256 campaignId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(c.status == CampaignStatus.Active && block.timestamp < c.deadline, "Not active");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Don't exceed hard cap
        euint64 remaining = FHE.sub(c.hardCap, c.totalRaised);
        ebool underHardCap = FHE.le(amount, remaining);
        euint64 accepted = FHE.select(underHardCap, amount, remaining);
        _contributions[campaignId][msg.sender] = FHE.add(_contributions[campaignId][msg.sender], accepted);
        c.totalRaised = FHE.add(c.totalRaised, accepted);
        FHE.allowThis(_contributions[campaignId][msg.sender]);
        FHE.allow(_contributions[campaignId][msg.sender], msg.sender);
        FHE.allowThis(c.totalRaised);
        _hasContributed[campaignId][msg.sender] = true;
        if (!FHE.isInitialized(_refundBalance[msg.sender])) {
            _refundBalance[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_refundBalance[msg.sender]);
        }
        // Check if hard cap hit
        ebool hardCapHit = FHE.ge(c.totalRaised, c.hardCap);
        if (FHE.isInitialized(hardCapHit)) {
            c.status = CampaignStatus.HardCapReached;
            emit CampaignSucceeded(campaignId, true);
        }
        emit ContributionMade(campaignId, msg.sender);
    }

    function finalizeCampaign(uint256 campaignId) external {
        Campaign storage c = campaigns[campaignId];
        require(block.timestamp >= c.deadline && c.status == CampaignStatus.Active, "Not ready");
        ebool metSoftCap = FHE.ge(c.totalRaised, c.softCap);
        if (FHE.isInitialized(metSoftCap)) {
            c.status = CampaignStatus.SoftCapReached;
            emit CampaignSucceeded(campaignId, false);
        } else {
            c.status = CampaignStatus.Failed;
            emit CampaignFailed(campaignId);
        }
    }

    function creatorWithdraw(uint256 campaignId) external nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(c.creator == msg.sender && !c.claimedByCreator, "Invalid");
        require(c.status == CampaignStatus.SoftCapReached || c.status == CampaignStatus.HardCapReached, "Not succeeded");
        c.claimedByCreator = true;
        euint64 fee = FHE.div(FHE.mul(c.totalRaised, c.platformFeeBps), 10000);
        euint64 creatorNet = FHE.sub(c.totalRaised, fee);
        _totalPlatformFees = FHE.add(_totalPlatformFees, fee);
        FHE.allowThis(_totalPlatformFees);
        FHE.allow(creatorNet, msg.sender);
        FHE.allow(fee, platformTreasury);
        emit FundsWithdrawn(campaignId, msg.sender);
    }

    function refundContribution(uint256 campaignId) external nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(c.status == CampaignStatus.Failed || c.status == CampaignStatus.Refunding, "Not refundable");
        require(_hasContributed[campaignId][msg.sender], "Not contributor");
        euint64 refund = _contributions[campaignId][msg.sender];
        _contributions[campaignId][msg.sender] = FHE.asEuint64(0);
        _refundBalance[msg.sender] = FHE.add(_refundBalance[msg.sender], refund);
        FHE.allowThis(_contributions[campaignId][msg.sender]);
        FHE.allowThis(_refundBalance[msg.sender]);
        FHE.allow(_refundBalance[msg.sender], msg.sender);
        emit RefundIssued(campaignId, msg.sender);
    }

    function withdrawRefund() external nonReentrant {
        euint64 refund = _refundBalance[msg.sender];
        _refundBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_refundBalance[msg.sender]);
        FHE.allow(refund, msg.sender);
    }

    function allowCampaignStats(uint256 id, address viewer) external onlyOwner {
        FHE.allow(campaigns[id].softCap, viewer);
        FHE.allow(campaigns[id].hardCap, viewer);
        FHE.allow(campaigns[id].totalRaised, viewer);
    }
}
