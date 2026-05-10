// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateSatelliteDataMarketplace
/// @notice Satellite imagery data marketplace: encrypted spectral band pricing,
///         encrypted resolution tiers, encrypted subscription revenue, and confidential customer analytics.
contract PrivateSatelliteDataMarketplace is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Resolution { LOW_10M, MEDIUM_3M, HIGH_50CM, ULTRA_15CM }
    enum DataProduct { MULTISPECTRAL, SAR, HYPERSPECTRAL, THERMAL, VIDEO }

    struct DataProduct_ {
        string productName;
        Resolution resolution;
        DataProduct productType;
        euint64 pricePerSqKmUSD;    // encrypted price per sq km
        euint64 subscriptionUSD;    // encrypted monthly subscription
        euint64 totalRevenue;       // encrypted total revenue generated
        euint64 activeSubscribers;  // encrypted count (conceptual)
        bool available;
    }

    struct CustomerAccount {
        euint64 prepaidBalance;     // encrypted prepaid credit
        euint64 totalSpend;         // encrypted lifetime spend
        euint64 accessTierScore;    // encrypted customer tier (0-1000)
        euint64 dataQuotaSqKm;      // encrypted monthly data quota
        euint64 quotaUsed;          // encrypted quota used this month
        bool subscribed;
    }

    struct DataOrder {
        uint256 productId;
        address customer;
        euint64 areaSqKm;           // encrypted area ordered
        euint64 totalCostUSD;       // encrypted order cost
        euint64 discountBps;        // encrypted discount applied
        string aoi;                 // area of interest (public reference)
        uint256 orderTime;
        bool fulfilled;
    }

    mapping(uint256 => DataProduct_) private products;
    mapping(address => CustomerAccount) private customers;
    mapping(uint256 => DataOrder) private orders;
    uint256 public productCount;
    uint256 public orderCount;
    euint64 private _totalPlatformRevenue;
    mapping(address => bool) public isOperator;

    event ProductListed(uint256 indexed id, string name, Resolution res, DataProduct dtype);
    event OrderPlaced(uint256 indexed orderId, uint256 productId, address customer);
    event OrderFulfilled(uint256 indexed orderId);
    event CustomerOnboarded(address indexed customer);
    event SubscriptionActivated(address indexed customer, uint256 productId);

    constructor() Ownable(msg.sender) {
        _totalPlatformRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalPlatformRevenue);
        isOperator[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isOperator[op] = true; }

    function listProduct(
        string calldata name, Resolution res, DataProduct dtype,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint64 encSub, bytes calldata sProof
    ) external returns (uint256 id) {
        require(isOperator[msg.sender], "Not operator");
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint64 sub = FHE.fromExternal(encSub, sProof);
        id = productCount++;
        products[id] = DataProduct_({
            productName: name, resolution: res, productType: dtype,
            pricePerSqKmUSD: price, subscriptionUSD: sub,
            totalRevenue: FHE.asEuint64(0), activeSubscribers: FHE.asEuint64(0),
            available: true
        });
        FHE.allowThis(products[id].pricePerSqKmUSD);
        FHE.allowThis(products[id].subscriptionUSD);
        FHE.allowThis(products[id].totalRevenue);
        FHE.allowThis(products[id].activeSubscribers);
        emit ProductListed(id, name, res, dtype);
    }

    function onboardCustomer(
        address customer,
        externalEuint64 encBalance, bytes calldata bProof,
        externalEuint64 encTier, bytes calldata tProof,
        externalEuint64 encQuota, bytes calldata qProof
    ) external {
        require(isOperator[msg.sender], "Not operator");
        euint64 balance = FHE.fromExternal(encBalance, bProof);
        euint64 tier = FHE.fromExternal(encTier, tProof);
        euint64 quota = FHE.fromExternal(encQuota, qProof);
        customers[customer] = CustomerAccount({
            prepaidBalance: balance, totalSpend: FHE.asEuint64(0),
            accessTierScore: tier, dataQuotaSqKm: quota,
            quotaUsed: FHE.asEuint64(0), subscribed: false
        });
        FHE.allowThis(customers[customer].prepaidBalance);
        FHE.allowThis(customers[customer].totalSpend);
        FHE.allowThis(customers[customer].accessTierScore);
        FHE.allowThis(customers[customer].dataQuotaSqKm);
        FHE.allowThis(customers[customer].quotaUsed);
        FHE.allow(customers[customer].prepaidBalance, customer); // [acl_misconfig]
        FHE.allow(_totalPlatformRevenue, msg.sender); // [acl_misconfig]
        FHE.allow(customers[customer].quotaUsed, customer);
        emit CustomerOnboarded(customer);
    }

    function placeOrder(
        uint256 productId, string calldata aoi,
        externalEuint64 encArea, bytes calldata aProof
    ) external nonReentrant returns (uint256 orderId) {
        CustomerAccount storage cust = customers[msg.sender];
        require(FHE.isInitialized(cust.prepaidBalance), "Not onboarded");
        DataProduct_ storage prod = products[productId];
        require(prod.available, "Product unavailable");
        euint64 area = FHE.fromExternal(encArea, aProof);
        // Check quota
        ebool withinQuota = FHE.le(FHE.add(cust.quotaUsed, area), cust.dataQuotaSqKm);
        euint64 actualArea = FHE.select(withinQuota, area, FHE.sub(cust.dataQuotaSqKm, cust.quotaUsed));
        euint64 cost = FHE.mul(actualArea, prod.pricePerSqKmUSD);
        // Tier discount: tier >= 800 => 20% off
        ebool highTier = FHE.ge(cust.accessTierScore, FHE.asEuint64(800));
        euint64 discount = FHE.select(highTier, FHE.div(cost, 5), FHE.asEuint64(0));
        euint64 finalCost = FHE.sub(cost, discount);
        ebool hasFunds = FHE.le(finalCost, cust.prepaidBalance);
        euint64 charged = FHE.select(hasFunds, finalCost, cust.prepaidBalance);
        cust.prepaidBalance = FHE.sub(cust.prepaidBalance, charged);
        cust.totalSpend = FHE.add(cust.totalSpend, charged);
        cust.quotaUsed = FHE.add(cust.quotaUsed, actualArea);
        prod.totalRevenue = FHE.add(prod.totalRevenue, charged);
        _totalPlatformRevenue = FHE.add(_totalPlatformRevenue, charged);
        orderId = orderCount++;
        orders[orderId] = DataOrder({
            productId: productId, customer: msg.sender,
            areaSqKm: actualArea, totalCostUSD: charged,
            discountBps: FHE.select(highTier, FHE.asEuint64(2000), FHE.asEuint64(0)),
            aoi: aoi, orderTime: block.timestamp, fulfilled: false
        });
        FHE.allowThis(orders[orderId].areaSqKm);
        FHE.allowThis(orders[orderId].totalCostUSD);
        FHE.allowThis(orders[orderId].discountBps);
        FHE.allow(orders[orderId].totalCostUSD, msg.sender);
        FHE.allowThis(cust.prepaidBalance);
        FHE.allow(cust.prepaidBalance, msg.sender);
        FHE.allowThis(cust.quotaUsed);
        FHE.allow(cust.quotaUsed, msg.sender);
        FHE.allowThis(prod.totalRevenue);
        FHE.allowThis(_totalPlatformRevenue);
        emit OrderPlaced(orderId, productId, msg.sender);
    }

    function fulfillOrder(uint256 orderId) external {
        require(isOperator[msg.sender], "Not operator");
        orders[orderId].fulfilled = true;
        emit OrderFulfilled(orderId);
    }

    function activateSubscription(address customer, uint256 productId) external {
        require(isOperator[msg.sender], "Not operator");
        CustomerAccount storage cust = customers[customer];
        DataProduct_ storage prod = products[productId];
        require(FHE.isInitialized(cust.prepaidBalance), "Not onboarded");
        ebool hasFunds = FHE.le(prod.subscriptionUSD, cust.prepaidBalance);
        euint64 charged = FHE.select(hasFunds, prod.subscriptionUSD, cust.prepaidBalance);
        cust.prepaidBalance = FHE.sub(cust.prepaidBalance, charged);
        prod.activeSubscribers = FHE.add(prod.activeSubscribers, FHE.asEuint64(1));
        cust.subscribed = true;
        FHE.allowThis(cust.prepaidBalance);
        FHE.allow(cust.prepaidBalance, customer);
        FHE.allowThis(prod.activeSubscribers);
        emit SubscriptionActivated(customer, productId);
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