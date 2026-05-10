// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateIoTDataMarketplaceSubscription
/// @notice Encrypted IoT sensor data marketplace: hidden data stream pricing per device,
///         confidential subscriber access tiers, private data quality scores, and encrypted
///         revenue distribution to sensor network operators.
contract PrivateIoTDataMarketplaceSubscription is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum DataCategory { EnvironmentalSensors, SmartGrid, SupplyChain, HealthMonitoring, SmartCityTraffic }
    enum SubscriptionTier { Free, Basic, Professional, Enterprise }

    struct DataStream {
        address networkOperator;
        DataCategory category;
        string streamId;
        string geoRegion;
        euint64 pricePerMonthUSD;      // encrypted monthly subscription price
        euint32 deviceCount;           // encrypted number of devices
        euint16 qualityScoreBps;       // encrypted data quality score
        euint64 totalRevenueUSD;       // encrypted stream revenue
        euint32 activeSubscribers;     // encrypted active subscriber count
        bool active;
    }

    struct DataSubscription {
        uint256 streamId;
        address subscriber;
        SubscriptionTier tier;
        euint64 monthlyFeeUSD;         // encrypted fee paid
        euint16 accessScopeFlags;      // encrypted access scope bitmap
        uint256 subscriptionStart;
        uint256 subscriptionEnd;
        bool active;
    }

    mapping(uint256 => DataStream) private streams;
    mapping(uint256 => DataSubscription) private subscriptions;
    mapping(address => bool) public isMarketplaceAdmin;

    uint256 public streamCount;
    uint256 public subscriptionCount;
    euint64 private _totalMarketplaceRevenueUSD;
    euint64 private _totalOperatorPayoutsUSD;

    event StreamRegistered(uint256 indexed id, DataCategory category, string streamId);
    event SubscriptionCreated(uint256 indexed subId, uint256 streamId, address subscriber);

    modifier onlyMarketplaceAdmin() {
        require(isMarketplaceAdmin[msg.sender] || msg.sender == owner(), "Not marketplace admin");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalMarketplaceRevenueUSD = FHE.asEuint64(0);
        _totalOperatorPayoutsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalMarketplaceRevenueUSD);
        FHE.allowThis(_totalOperatorPayoutsUSD);
        isMarketplaceAdmin[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addAdmin(address a) external onlyOwner { isMarketplaceAdmin[a] = true; }

    function registerDataStream(
        DataCategory category, string calldata streamId, string calldata geoRegion,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint32 encDeviceCount, bytes calldata dcProof,
        externalEuint16 encQuality, bytes calldata qProof
    ) external whenNotPaused returns (uint256 id) {
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint64 priceWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 priceExposure = FHE.sub(priceWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint32 deviceCount = FHE.fromExternal(encDeviceCount, dcProof);
        euint16 quality = FHE.fromExternal(encQuality, qProof);
        id = streamCount++;
        streams[id].networkOperator = msg.sender;
        streams[id].category = category;
        streams[id].streamId = streamId;
        streams[id].geoRegion = geoRegion;
        streams[id].pricePerMonthUSD = price;
        streams[id].deviceCount = deviceCount;
        streams[id].qualityScoreBps = quality;
        streams[id].totalRevenueUSD = FHE.asEuint64(0);
        streams[id].activeSubscribers = FHE.asEuint32(0);
        streams[id].active = true;
        FHE.allowThis(streams[id].pricePerMonthUSD); FHE.allow(streams[id].pricePerMonthUSD, msg.sender);
        FHE.allowThis(streams[id].deviceCount); FHE.allow(streams[id].deviceCount, msg.sender);
        FHE.allowThis(streams[id].qualityScoreBps);
        FHE.allowThis(streams[id].totalRevenueUSD); FHE.allow(streams[id].totalRevenueUSD, msg.sender);
        FHE.allowThis(streams[id].activeSubscribers);
        emit StreamRegistered(id, category, streamId);
    }

    function createSubscription(
        uint256 streamId_, SubscriptionTier tier,
        externalEuint16 encAccessScope, bytes calldata asProof,
        uint256 durationDays
    ) external whenNotPaused nonReentrant returns (uint256 subId) {
        DataStream storage ds = streams[streamId_];
        require(ds.active, "Stream not active");
        euint16 accessScope = FHE.fromExternal(encAccessScope, asProof);
        subId = subscriptionCount++;
        subscriptions[subId] = DataSubscription({
            streamId: streamId_, subscriber: msg.sender, tier: tier,
            monthlyFeeUSD: ds.pricePerMonthUSD, accessScopeFlags: accessScope,
            subscriptionStart: block.timestamp, subscriptionEnd: block.timestamp + durationDays * 1 days,
            active: true
        });
        ds.totalRevenueUSD = FHE.add(ds.totalRevenueUSD, ds.pricePerMonthUSD);
        ds.activeSubscribers = FHE.add(ds.activeSubscribers, FHE.asEuint32(1));
        // Operator gets 80% (plaintext divisor)
        euint64 operatorPayout = FHE.div(FHE.mul(ds.pricePerMonthUSD, 80), 100);
        _totalMarketplaceRevenueUSD = FHE.add(_totalMarketplaceRevenueUSD, ds.pricePerMonthUSD);
        _totalOperatorPayoutsUSD = FHE.add(_totalOperatorPayoutsUSD, operatorPayout);
        FHE.allowThis(subscriptions[subId].monthlyFeeUSD); FHE.allow(subscriptions[subId].monthlyFeeUSD, msg.sender);
        FHE.allowThis(subscriptions[subId].accessScopeFlags); FHE.allow(subscriptions[subId].accessScopeFlags, msg.sender);
        FHE.allowThis(ds.totalRevenueUSD); FHE.allow(ds.totalRevenueUSD, ds.networkOperator);
        FHE.allowThis(ds.activeSubscribers);
        FHE.allowThis(_totalMarketplaceRevenueUSD);
        FHE.allowThis(_totalOperatorPayoutsUSD);
        emit SubscriptionCreated(subId, streamId_, msg.sender);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalMarketplaceRevenueUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalMarketplaceRevenueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalOperatorPayoutsUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalOperatorPayoutsUSD, viewer);
    }
}
