// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title RoleBasedContentGating - Encrypted content tier access with dynamic role assignment
contract RoleBasedContentGating is ZamaEthereumConfig, AccessControl {
    bytes32 public constant CONTENT_ADMIN = keccak256("CONTENT_ADMIN");
    bytes32 public constant PREMIUM_USER = keccak256("PREMIUM_USER");
    bytes32 public constant STANDARD_USER = keccak256("STANDARD_USER");

    struct ContentItem {
        string contentId;
        euint8 requiredAccessLevel; // 1=free, 2=standard, 3=premium, 4=enterprise
        euint32 viewCount;
        euint64 revenueAccrued;
        bool active;
    }

    struct UserProfile {
        euint8 accessLevel;
        euint32 contentConsumed;
        euint64 spentAmount;
        uint256 subscriptionExpiry;
    }

    mapping(uint256 => ContentItem) public content;
    mapping(address => UserProfile) public userProfiles;
    uint256 public contentCount;

    event ContentPublished(uint256 indexed contentId);
    event ContentAccessed(uint256 indexed contentId, address indexed user);
    event UserUpgraded(address indexed user);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CONTENT_ADMIN, msg.sender);
    }

    function publishContent(
        string calldata contentId,
        externalEuint8 encLevel,
        bytes calldata inputProof
    ) external onlyRole(CONTENT_ADMIN) returns (uint256 id) {
        id = contentCount++;
        ContentItem storage c = content[id];
        c.contentId = contentId;
        c.requiredAccessLevel = FHE.fromExternal(encLevel, inputProof);
        c.viewCount = FHE.asEuint32(0);
        c.revenueAccrued = FHE.asEuint64(0);
        c.active = true;
        FHE.allowThis(c.requiredAccessLevel);
        FHE.allowThis(c.viewCount);
        FHE.allowThis(c.revenueAccrued);
        emit ContentPublished(id);
    }

    function setupUserProfile(
        address user,
        externalEuint8 encLevel,
        bytes calldata inputProof,
        uint256 subscriptionDays
    ) external onlyRole(CONTENT_ADMIN) {
        UserProfile storage p = userProfiles[user];
        p.accessLevel = FHE.fromExternal(encLevel, inputProof);
        p.contentConsumed = FHE.asEuint32(0);
        p.spentAmount = FHE.asEuint64(0);
        p.subscriptionExpiry = block.timestamp + subscriptionDays * 1 days;
        FHE.allowThis(p.accessLevel);
        FHE.allowThis(p.contentConsumed);
        FHE.allowThis(p.spentAmount);
        FHE.allow(p.accessLevel, user);
        FHE.allow(p.contentConsumed, user);
    }

    function accessContent(uint256 contentId, externalEuint64 encPayment, bytes calldata inputProof) external {
        UserProfile storage p = userProfiles[msg.sender];
        ContentItem storage c = content[contentId];
        require(c.active, "Not active");
        require(block.timestamp <= p.subscriptionExpiry, "Subscription expired");

        ebool hasAccess = FHE.ge(p.accessLevel, c.requiredAccessLevel);
        euint64 payment = FHE.fromExternal(encPayment, inputProof);
        euint64 safePayment = FHE.select(hasAccess, payment, FHE.asEuint64(0));

        c.viewCount = FHE.add(c.viewCount, FHE.select(hasAccess, FHE.asEuint32(1), FHE.asEuint32(0)));
        c.revenueAccrued = FHE.add(c.revenueAccrued, safePayment);
        p.contentConsumed = FHE.add(p.contentConsumed, FHE.select(hasAccess, FHE.asEuint32(1), FHE.asEuint32(0)));
        p.spentAmount = FHE.add(p.spentAmount, safePayment);

        FHE.allowThis(c.viewCount);
        FHE.allowThis(c.revenueAccrued);
        FHE.allowThis(p.contentConsumed);
        FHE.allowThis(p.spentAmount);
        FHE.allow(p.contentConsumed, msg.sender);
        emit ContentAccessed(contentId, msg.sender);
    }
}
