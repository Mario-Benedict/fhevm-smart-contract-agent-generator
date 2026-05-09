// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateAPIGateway - Encrypted subscription-based API access control
contract PrivateAPIGateway is ZamaEthereumConfig, Ownable {
    struct Subscription {
        euint32 requestsRemaining;
        euint8 tierLevel;        // 1=basic, 2=pro, 3=enterprise
        euint32 expiresAt;
        bool active;
    }

    struct APIEndpoint {
        string path;
        euint8 requiredTier;
        euint32 requestCost;
        bool enabled;
    }

    mapping(address => Subscription) public subscriptions;
    mapping(uint256 => APIEndpoint) public endpoints;
    mapping(address => euint32) public totalRequestsMade;
    mapping(address => bool) private _requestsInitialized;
    uint256 public endpointCount;

    event SubscriptionCreated(address indexed subscriber);
    event SubscriptionRenewed(address indexed subscriber);
    event APICallRecorded(address indexed caller, uint256 endpointId);
    event EndpointRegistered(uint256 indexed endpointId, string path);

    constructor() Ownable(msg.sender) {}

    function registerEndpoint(
        string calldata path,
        externalEuint8 encTier,
        bytes calldata tierProof,
        externalEuint32 encCost,
        bytes calldata costProof
    ) external onlyOwner returns (uint256 endpointId) {
        endpointId = endpointCount++;
        APIEndpoint storage e = endpoints[endpointId];
        e.path = path;
        e.requiredTier = FHE.fromExternal(encTier, tierProof);
        e.requestCost = FHE.fromExternal(encCost, costProof);
        e.enabled = true;
        FHE.allowThis(e.requiredTier);
        FHE.allowThis(e.requestCost);
        emit EndpointRegistered(endpointId, path);
    }

    function createSubscription(
        address subscriber,
        externalEuint8 encTier,
        bytes calldata tierProof,
        externalEuint32 encRequests,
        bytes calldata requestsProof,
        uint32 durationDays
    ) external onlyOwner {
        Subscription storage s = subscriptions[subscriber];
        s.tierLevel = FHE.fromExternal(encTier, tierProof);
        s.requestsRemaining = FHE.fromExternal(encRequests, requestsProof);
        s.expiresAt = FHE.asEuint32(uint32(block.timestamp) + durationDays * 1 days);
        s.active = true;
        FHE.allowThis(s.tierLevel);
        FHE.allowThis(s.requestsRemaining);
        FHE.allowThis(s.expiresAt);
        FHE.allow(s.tierLevel, subscriber);
        FHE.allow(s.requestsRemaining, subscriber);
        FHE.allow(s.expiresAt, subscriber);
        if (!_requestsInitialized[subscriber]) {
            totalRequestsMade[subscriber] = FHE.asEuint32(0);
            FHE.allowThis(totalRequestsMade[subscriber]);
            _requestsInitialized[subscriber] = true;
        }
        emit SubscriptionCreated(subscriber);
    }

    function recordAPICall(address caller, uint256 endpointId) external onlyOwner {
        Subscription storage s = subscriptions[caller];
        require(s.active, "No subscription");
        APIEndpoint storage e = endpoints[endpointId];
        require(e.enabled, "Endpoint disabled");

        ebool tierOk = FHE.ge(s.tierLevel, e.requiredTier);
        ebool hasRequests = FHE.gt(s.requestsRemaining, FHE.asEuint32(0));
        ebool canAccess = FHE.and(tierOk, hasRequests);

        euint32 deduct = FHE.select(canAccess, e.requestCost, FHE.asEuint32(0));
        s.requestsRemaining = FHE.sub(s.requestsRemaining, deduct);
        totalRequestsMade[caller] = FHE.add(totalRequestsMade[caller], FHE.select(canAccess, FHE.asEuint32(1), FHE.asEuint32(0)));

        FHE.allowThis(s.requestsRemaining);
        FHE.allowThis(totalRequestsMade[caller]);
        FHE.allow(s.requestsRemaining, caller);
        emit APICallRecorded(caller, endpointId);
    }
}
