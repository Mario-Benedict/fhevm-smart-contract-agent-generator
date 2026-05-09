// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SecretContentPlatform - Creator platform with encrypted content tiers and private subscriber counts
contract SecretContentPlatform is ZamaEthereumConfig, Ownable {
    struct ContentTier {
        string tierName;
        euint64 monthlyPriceSats; // encrypted monthly price
        euint32 subscriberCount;  // encrypted subscriber count
        euint64 totalRevenue;     // encrypted earnings
    }

    struct Creator {
        ContentTier[] tiers;
        euint64 totalEarnings;
        bool active;
    }

    struct Subscription {
        uint256 tierId;
        uint256 expiresAt;
        euint64 pricePaid;
        bool active;
    }

    mapping(address => Creator) private creators;
    mapping(address => mapping(address => Subscription)) private subscriptions; // subscriber => creator => sub
    mapping(address => bool) public isVerifiedCreator;

    event CreatorRegistered(address indexed creator);
    event TierCreated(address indexed creator, uint256 tierId);
    event Subscribed(address indexed subscriber, address creator, uint256 tierId);
    event CreatorWithdraw(address indexed creator);

    constructor() Ownable(msg.sender) {}

    function registerCreator() external {
        require(!isVerifiedCreator[msg.sender], "Already registered");
        isVerifiedCreator[msg.sender] = true;
        creators[msg.sender].totalEarnings = FHE.asEuint64(0);
        creators[msg.sender].active = true;
        FHE.allowThis(creators[msg.sender].totalEarnings);
        FHE.allow(creators[msg.sender].totalEarnings, msg.sender);
        emit CreatorRegistered(msg.sender);
    }

    function addTier(
        string calldata name,
        externalEuint64 encPrice, bytes calldata proof
    ) external returns (uint256 tierId) {
        require(isVerifiedCreator[msg.sender], "Not creator");
        euint64 price = FHE.fromExternal(encPrice, proof);
        tierId = creators[msg.sender].tiers.length;
        creators[msg.sender].tiers.push(ContentTier({ tierName: name, monthlyPriceSats: price,
            subscriberCount: FHE.asEuint32(0), totalRevenue: FHE.asEuint64(0) }));
        FHE.allowThis(creators[msg.sender].tiers[tierId].monthlyPriceSats);
        FHE.allow(creators[msg.sender].tiers[tierId].monthlyPriceSats, msg.sender);
        FHE.allowThis(creators[msg.sender].tiers[tierId].subscriberCount);
        FHE.allowThis(creators[msg.sender].tiers[tierId].totalRevenue);
        emit TierCreated(msg.sender, tierId);
    }

    function subscribe(address creator, uint256 tierId, externalEuint64 encAmount, bytes calldata proof) external {
        require(isVerifiedCreator[creator] && creators[creator].tiers.length > tierId, "Invalid");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ContentTier storage tier = creators[creator].tiers[tierId];
        // Check payment meets price
        ebool paid = FHE.ge(amount, tier.monthlyPriceSats);
        euint64 actualPayment = FHE.select(paid, amount, FHE.asEuint64(0));
        tier.subscriberCount = FHE.add(tier.subscriberCount, FHE.asEuint32(1));
        tier.totalRevenue = FHE.add(tier.totalRevenue, actualPayment);
        creators[creator].totalEarnings = FHE.add(creators[creator].totalEarnings, actualPayment);
        FHE.allowThis(tier.subscriberCount); FHE.allowThis(tier.totalRevenue);
        FHE.allowThis(creators[creator].totalEarnings);
        FHE.allow(creators[creator].totalEarnings, creator);
        subscriptions[msg.sender][creator] = Subscription({ tierId: tierId,
            expiresAt: block.timestamp + 30 days, pricePaid: actualPayment, active: true });
        FHE.allowThis(subscriptions[msg.sender][creator].pricePaid);
        FHE.allow(subscriptions[msg.sender][creator].pricePaid, msg.sender);
        emit Subscribed(msg.sender, creator, tierId);
    }

    function isSubscribed(address subscriber, address creator) external view returns (bool) {
        Subscription storage sub = subscriptions[subscriber][creator];
        return sub.active && block.timestamp < sub.expiresAt;
    }

    function withdraw() external {
        require(isVerifiedCreator[msg.sender], "Not creator");
        euint64 earnings = creators[msg.sender].totalEarnings;
        creators[msg.sender].totalEarnings = FHE.asEuint64(0);
        FHE.allowThis(creators[msg.sender].totalEarnings);
        FHE.allow(earnings, msg.sender);
        emit CreatorWithdraw(msg.sender);
    }

    function allowCreatorStats(address creator, address viewer) external {
        require(msg.sender == creator || msg.sender == owner(), "Unauthorized");
        FHE.allow(creators[creator].totalEarnings, viewer);
    }
}
