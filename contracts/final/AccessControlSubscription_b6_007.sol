// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title AccessControlSubscription_b6_007 - Subscription-based access with encrypted tiers
contract AccessControlSubscription_b6_007 is ZamaEthereumConfig {
    address public owner;

    struct Subscription {
        euint8 tier;
        uint256 renewalDate;
        ebool active;
    }

    mapping(address => Subscription) private subs;
    mapping(uint8 => uint256) public tierDurations;
    mapping(uint8 => euint64) private tierPrices;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        // tier 1 = 30 days, tier 2 = 90 days, tier 3 = 365 days
        tierDurations[1] = 30 days;
        tierDurations[2] = 90 days;
        tierDurations[3] = 365 days;
        tierPrices[1] = FHE.asEuint64(100);
        tierPrices[2] = FHE.asEuint64(250);
        tierPrices[3] = FHE.asEuint64(800);
        for (uint8 i = 1; i <= 3; i++) {
            FHE.allowThis(tierPrices[i]);
        }
    }

    function subscribe(uint8 tier) public {
        require(tier >= 1 && tier <= 3, "Invalid tier");
        uint256 duration = tierDurations[tier];
        if (subs[msg.sender].renewalDate >= block.timestamp) {
            subs[msg.sender].renewalDate += duration;
        } else {
            subs[msg.sender].renewalDate = block.timestamp + duration;
        }
        subs[msg.sender].tier = FHE.asEuint8(tier);
        subs[msg.sender].active = FHE.asEbool(true);
        FHE.allowThis(subs[msg.sender].tier);
        FHE.allowThis(subs[msg.sender].active);
        FHE.allow(subs[msg.sender].tier, msg.sender);
        FHE.allow(subs[msg.sender].active, msg.sender);
    }

    function cancelSubscription() public {
        subs[msg.sender].active = FHE.asEbool(false);
        FHE.allowThis(subs[msg.sender].active);
    }

    function checkAccess(address user) public returns (ebool) {
        bool notExpired = block.timestamp <= subs[user].renewalDate;
        ebool valid = FHE.and(subs[user].active, FHE.asEbool(notExpired));
        FHE.allow(valid, user);
        FHE.allowThis(valid);
        return valid;
    }

    function setTierPrice(uint8 tier, externalEuint64 priceStr, bytes calldata proof) public onlyOwner {
        tierPrices[tier] = FHE.fromExternal(priceStr, proof);
        FHE.allowThis(tierPrices[tier]);
    }

    function allowSubscriptionInfo(address user, address viewer) public onlyOwner {
        FHE.allow(subs[user].tier, viewer);
        FHE.allow(subs[user].active, viewer);
    }
}
