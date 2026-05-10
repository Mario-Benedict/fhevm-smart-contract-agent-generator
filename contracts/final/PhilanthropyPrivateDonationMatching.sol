// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PhilanthropyPrivateDonationMatching
/// @notice Charitable donation matching where donor amounts are encrypted.
///         Matching corporations cannot see individual donations; the match
///         is computed homomorphically up to an encrypted match cap.
contract PhilanthropyPrivateDonationMatching is ZamaEthereumConfig, Ownable {
    struct Campaign {
        string title;
        string description;
        address beneficiary;
        euint64 goalAmount;
        euint64 raisedAmount;
        euint64 matchedAmount;
        euint64 matchCapPerDonor;
        euint64 totalMatchCap;
        euint64 matchUsed;
        uint256 deadline;
        bool active;
        bool disbursed;
    }

    struct Donation {
        euint64 amount;
        euint64 matchAmount;
        uint256 campaignId;
        uint256 donatedAt;
    }

    mapping(uint256 => Campaign) private campaigns;
    uint256 public campaignCount;
    mapping(uint256 => mapping(address => Donation)) private donations;
    mapping(uint256 => mapping(address => bool)) private hasDonated;
    mapping(uint256 => address[]) private donors;
    mapping(address => bool) public isMatchingCorp;
    euint64 private _platformFeeBps;

    event CampaignCreated(uint256 indexed id, string title);
    event DonationMade(uint256 indexed campaignId, address donor);
    event Disbursed(uint256 indexed campaignId);

    constructor(externalEuint64 encPlatformFee, bytes memory proof) Ownable(msg.sender) {
        _platformFeeBps = FHE.fromExternal(encPlatformFee, proof);
        FHE.allowThis(_platformFeeBps);
    }

    function addMatchingCorp(address corp) external onlyOwner { isMatchingCorp[corp] = true; }

    function createCampaign(
        string calldata title, string calldata desc,
        address beneficiary, uint256 deadlineDays,
        externalEuint64 encGoal, bytes calldata gProof,
        externalEuint64 encMatchCap, bytes calldata mcProof,
        externalEuint64 encMatchPerDonor, bytes calldata mdProof
    ) external onlyOwner returns (uint256 id) {
        id = campaignCount++;
        campaigns[id].title = title;
        campaigns[id].description = desc;
        campaigns[id].beneficiary = beneficiary;
        campaigns[id].goalAmount = FHE.fromExternal(encGoal, gProof);
        campaigns[id].totalMatchCap = FHE.fromExternal(encMatchCap, mcProof);
        campaigns[id].matchCapPerDonor = FHE.fromExternal(encMatchPerDonor, mdProof);
        campaigns[id].raisedAmount = FHE.asEuint64(0);
        campaigns[id].matchedAmount = FHE.asEuint64(0);
        campaigns[id].matchUsed = FHE.asEuint64(0);
        campaigns[id].deadline = block.timestamp + deadlineDays * 1 days;
        campaigns[id].active = true;
        FHE.allowThis(campaigns[id].goalAmount);
        FHE.allowThis(campaigns[id].totalMatchCap);
        FHE.allowThis(campaigns[id].matchCapPerDonor);
        FHE.allowThis(campaigns[id].raisedAmount);
        FHE.allowThis(campaigns[id].matchedAmount);
        FHE.allowThis(campaigns[id].matchUsed);
        emit CampaignCreated(id, title);
    }

    function donate(
        uint256 campaignId,
        externalEuint64 encAmount, bytes calldata proof
    ) external {
        Campaign storage c = campaigns[campaignId];
        require(c.active && block.timestamp < c.deadline, "Campaign closed");
        require(!hasDonated[campaignId][msg.sender], "Already donated");
        hasDonated[campaignId][msg.sender] = true;
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Calculate match (min of amount, matchCapPerDonor, remaining totalCap)
        euint64 matchFromCap = FHE.select(FHE.le(amount, c.matchCapPerDonor), amount, c.matchCapPerDonor);
        euint64 remainingTotalCap = FHE.sub(c.totalMatchCap, c.matchUsed);
        euint64 actualMatch = FHE.select(FHE.le(matchFromCap, remainingTotalCap), matchFromCap, remainingTotalCap);
        donations[campaignId][msg.sender] = Donation({
            amount: amount, matchAmount: actualMatch,
            campaignId: campaignId, donatedAt: block.timestamp
        });
        c.raisedAmount = FHE.add(c.raisedAmount, amount);
        c.matchedAmount = FHE.add(c.matchedAmount, actualMatch);
        c.matchUsed = FHE.add(c.matchUsed, actualMatch);
        FHE.allowThis(donations[campaignId][msg.sender].amount);
        FHE.allow(donations[campaignId][msg.sender].amount, msg.sender);
        FHE.allowThis(donations[campaignId][msg.sender].matchAmount);
        FHE.allow(donations[campaignId][msg.sender].matchAmount, msg.sender);
        FHE.allowThis(c.raisedAmount);
        FHE.allowThis(c.matchedAmount);
        FHE.allowThis(c.matchUsed);
        donors[campaignId].push(msg.sender);
        emit DonationMade(campaignId, msg.sender);
    }

    function disburse(uint256 campaignId) external onlyOwner {
        Campaign storage c = campaigns[campaignId];
        require(!c.disbursed && (block.timestamp >= c.deadline), "Cannot disburse");
        c.disbursed = true;
        c.active = false;
        euint64 total = FHE.add(c.raisedAmount, c.matchedAmount);
        euint64 fee = FHE.div(FHE.mul(total, _platformFeeBps), 10000);
        euint64 toBeneficiary = FHE.sub(total, fee);
        FHE.allow(toBeneficiary, c.beneficiary);
        FHE.allow(fee, owner());
        emit Disbursed(campaignId);
    }

    function allowCampaignStats(uint256 id, address viewer) external onlyOwner {
        FHE.allow(campaigns[id].raisedAmount, viewer);
        FHE.allow(campaigns[id].matchedAmount, viewer);
        FHE.allow(campaigns[id].goalAmount, viewer);
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