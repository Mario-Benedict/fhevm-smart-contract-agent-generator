// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedWhistleblowerBounty - Anonymous tip submission with encrypted identity and reward
contract EncryptedWhistleblowerBounty is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum TipStatus { Pending, UnderReview, Validated, Rejected, Rewarded }

    struct Tip {
        euint128 encryptedIdentity;  // encrypted submitter identity
        euint8   categoryCode;       // 1=fraud, 2=safety, 3=env, 4=corruption, 5=other
        euint8   severityLevel;      // 1-5
        string   evidenceHash;       // IPFS CID
        euint64  rewardAmount;
        TipStatus status;
        uint256  submittedAt;
        bool     identityRevealed;
    }

    struct RewardTier {
        euint8  minSeverity;
        euint64 baseReward;
        euint64 maxReward;
    }

    mapping(uint256 => Tip) public tips;
    mapping(uint256 => RewardTier) public rewardTiers;
    euint64 private bountyPool;
    uint256 public tipCount;
    uint256 public tierCount;

    event TipSubmitted(uint256 indexed tipId);
    event TipStatusUpdated(uint256 indexed tipId, TipStatus status);
    event RewardIssued(uint256 indexed tipId);
    event IdentityRevealed(uint256 indexed tipId);

    constructor() Ownable(msg.sender) {
        bountyPool = FHE.asEuint64(0);
        FHE.allowThis(bountyPool);
    }

    function fundBountyPool(externalEuint64 calldata encAmount, bytes calldata inputProof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        bountyPool = FHE.add(bountyPool, amount);
        FHE.allowThis(bountyPool);
    }

    function setRewardTier(
        uint256 tierId,
        externalEuint8  calldata encMinSev, bytes calldata minSevProof,
        externalEuint64 calldata encBase,   bytes calldata baseProof,
        externalEuint64 calldata encMax,    bytes calldata maxProof
    ) external onlyOwner {
        if (tierId >= tierCount) tierCount = tierId + 1;
        RewardTier storage t = rewardTiers[tierId];
        t.minSeverity = FHE.fromExternal(encMinSev, minSevProof);
        t.baseReward  = FHE.fromExternal(encBase,   baseProof);
        t.maxReward   = FHE.fromExternal(encMax,    maxProof);
        FHE.allowThis(t.minSeverity); FHE.allowThis(t.baseReward); FHE.allowThis(t.maxReward);
    }

    function submitTip(
        externalEuint128 calldata encIdentity, bytes calldata idProof,
        externalEuint8   calldata encCategory, bytes calldata catProof,
        externalEuint8   calldata encSeverity, bytes calldata sevProof,
        string calldata evidenceHash
    ) external returns (uint256 tipId) {
        tipId = tipCount++;
        Tip storage t = tips[tipId];
        t.encryptedIdentity = FHE.fromExternal(encIdentity, idProof);
        t.categoryCode      = FHE.fromExternal(encCategory, catProof);
        t.severityLevel     = FHE.fromExternal(encSeverity, sevProof);
        t.evidenceHash      = evidenceHash;
        t.rewardAmount      = FHE.asEuint64(0);
        t.status            = TipStatus.Pending;
        t.submittedAt       = block.timestamp;
        FHE.allowThis(t.encryptedIdentity); FHE.allowThis(t.categoryCode);
        FHE.allowThis(t.severityLevel); FHE.allowThis(t.rewardAmount);
        FHE.allow(t.encryptedIdentity, msg.sender); // only submitter can decrypt own identity
        emit TipSubmitted(tipId);
    }

    function updateTipStatus(uint256 tipId, TipStatus status) external onlyOwner {
        tips[tipId].status = status;
        if (status == TipStatus.Validated) {
            FHE.allow(tips[tipId].categoryCode, owner());
            FHE.allow(tips[tipId].severityLevel, owner());
        }
        emit TipStatusUpdated(tipId, status);
    }

    function issueReward(
        uint256 tipId,
        address payable recipient,
        externalEuint64 calldata encReward, bytes calldata inputProof
    ) external onlyOwner nonReentrant {
        Tip storage t = tips[tipId];
        require(t.status == TipStatus.Validated, "Not validated");
        euint64 reward = FHE.fromExternal(encReward, inputProof);
        t.rewardAmount = reward;
        t.status = TipStatus.Rewarded;
        bountyPool = FHE.sub(bountyPool, reward);
        FHE.allowThis(t.rewardAmount); FHE.allowThis(bountyPool);
        FHE.allow(t.rewardAmount, recipient);
        FHE.allowTransient(reward, recipient);
        emit RewardIssued(tipId);
    }

    function consentIdentityReveal(uint256 tipId) external {
        Tip storage t = tips[tipId];
        require(t.status == TipStatus.Rewarded, "Not rewarded");
        t.identityRevealed = true;
        FHE.allow(t.encryptedIdentity, owner());
        emit IdentityRevealed(tipId);
    }
}
