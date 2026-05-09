// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateTelcoDataPlanMarket
/// @notice Telecom data plan marketplace: operators offer encrypted data bundles,
///         users purchase with encrypted spend, usage tracked privately.
contract PrivateTelcoDataPlanMarket is ZamaEthereumConfig, Ownable {
    enum PlanType { Prepaid, Postpaid, MVNO, Enterprise }

    struct DataPlan {
        string planName;
        PlanType planType;
        string operator_;
        euint32 dataAllowanceMB;       // encrypted data in MB
        euint64 monthlyPriceUSD;       // encrypted monthly price
        euint16 speedMbps;             // encrypted max speed
        euint32 bonusDataMB;           // encrypted bonus data
        euint64 totalRevenue;          // encrypted revenue from this plan
        uint256 launchedAt;
        bool active;
    }

    struct UserSubscription {
        uint256 planId;
        euint32 dataUsedMB;            // encrypted data consumed
        euint32 dataRemainingMB;       // encrypted data remaining
        euint64 billAmountUSD;         // encrypted current bill
        euint64 totalSpentUSD;         // encrypted lifetime spend
        uint256 cycleStart;
        uint256 cycleEnd;
        bool active;
    }

    mapping(uint256 => DataPlan) private plans;
    mapping(address => UserSubscription) private subscriptions;
    mapping(address => bool) public isOperator;
    uint256 public planCount;
    euint64 private _totalMarketRevenue;
    euint32 private _totalActiveDataMB;

    event PlanListed(uint256 indexed id, string name);
    event PlanSubscribed(address indexed user, uint256 planId);
    event UsageReported(address indexed user);
    event BillGenerated(address indexed user);
    event PlanCancelled(address indexed user);

    modifier onlyOperator() {
        require(isOperator[msg.sender] || msg.sender == owner(), "Not operator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalMarketRevenue = FHE.asEuint64(0);
        _totalActiveDataMB = FHE.asEuint32(0);
        FHE.allowThis(_totalMarketRevenue);
        FHE.allowThis(_totalActiveDataMB);
        isOperator[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isOperator[op] = true; }

    function listPlan(
        string calldata name, PlanType planType, string calldata operator_,
        externalEuint32 encData, bytes calldata dPf,
        externalEuint64 encPrice, bytes calldata pPf,
        externalEuint16 encSpeed, bytes calldata sPf,
        externalEuint32 encBonus, bytes calldata bPf
    ) external onlyOperator returns (uint256 id) {
        euint32 data = FHE.fromExternal(encData, dPf);
        euint64 price = FHE.fromExternal(encPrice, pPf);
        euint16 speed = FHE.fromExternal(encSpeed, sPf);
        euint32 bonus = FHE.fromExternal(encBonus, bPf);
        id = planCount++;
        plans[id].planName = name;
        plans[id].planType = planType;
        plans[id].operator_ = operator_;
        plans[id].dataAllowanceMB = data;
        plans[id].monthlyPriceUSD = price;
        plans[id].speedMbps = speed;
        plans[id].bonusDataMB = bonus;
        plans[id].totalRevenue = FHE.asEuint64(0);
        plans[id].launchedAt = block.timestamp;
        plans[id].active = true;
        FHE.allowThis(plans[id].dataAllowanceMB);
        FHE.allowThis(plans[id].monthlyPriceUSD);
        FHE.allowThis(plans[id].speedMbps);
        FHE.allowThis(plans[id].bonusDataMB);
        FHE.allowThis(plans[id].totalRevenue);
        emit PlanListed(id, name);
    }

    function subscribe(uint256 planId) external {
        require(plans[planId].active, "Plan inactive");
        require(!subscriptions[msg.sender].active, "Already subscribed");
        DataPlan storage p = plans[planId];
        euint32 totalData = FHE.add(p.dataAllowanceMB, p.bonusDataMB);
        subscriptions[msg.sender] = UserSubscription({
            planId: planId, dataUsedMB: FHE.asEuint32(0),
            dataRemainingMB: totalData,
            billAmountUSD: p.monthlyPriceUSD,
            totalSpentUSD: FHE.asEuint64(0),
            cycleStart: block.timestamp, cycleEnd: block.timestamp + 30 days, active: true
        });
        p.totalRevenue = FHE.add(p.totalRevenue, p.monthlyPriceUSD);
        _totalMarketRevenue = FHE.add(_totalMarketRevenue, p.monthlyPriceUSD);
        _totalActiveDataMB = FHE.add(_totalActiveDataMB, totalData);
        FHE.allowThis(subscriptions[msg.sender].dataUsedMB);
        FHE.allow(subscriptions[msg.sender].dataUsedMB, msg.sender);
        FHE.allowThis(subscriptions[msg.sender].dataRemainingMB);
        FHE.allow(subscriptions[msg.sender].dataRemainingMB, msg.sender);
        FHE.allowThis(subscriptions[msg.sender].billAmountUSD);
        FHE.allow(subscriptions[msg.sender].billAmountUSD, msg.sender);
        FHE.allowThis(subscriptions[msg.sender].totalSpentUSD);
        FHE.allow(subscriptions[msg.sender].totalSpentUSD, msg.sender);
        FHE.allowThis(p.totalRevenue);
        FHE.allowThis(_totalMarketRevenue);
        FHE.allowThis(_totalActiveDataMB);
        emit PlanSubscribed(msg.sender, planId);
    }

    function reportUsage(address user, externalEuint32 encUsedMB, bytes calldata proof) external onlyOperator {
        UserSubscription storage s = subscriptions[user];
        require(s.active, "Not subscribed");
        euint32 used = FHE.fromExternal(encUsedMB, proof);
        ebool hasSuf = FHE.le(used, s.dataRemainingMB);
        euint32 actual = FHE.select(hasSuf, used, s.dataRemainingMB);
        s.dataUsedMB = FHE.add(s.dataUsedMB, actual);
        s.dataRemainingMB = FHE.sub(s.dataRemainingMB, actual);
        FHE.allowThis(s.dataUsedMB);
        FHE.allow(s.dataUsedMB, user);
        FHE.allowThis(s.dataRemainingMB);
        FHE.allow(s.dataRemainingMB, user);
        emit UsageReported(user);
    }

    function renewCycle(address user) external onlyOperator {
        UserSubscription storage s = subscriptions[user];
        require(block.timestamp > s.cycleEnd, "Cycle not ended");
        DataPlan storage p = plans[s.planId];
        s.dataUsedMB = FHE.asEuint32(0);
        s.dataRemainingMB = FHE.add(p.dataAllowanceMB, p.bonusDataMB);
        s.billAmountUSD = p.monthlyPriceUSD;
        s.totalSpentUSD = FHE.add(s.totalSpentUSD, p.monthlyPriceUSD);
        s.cycleStart = block.timestamp;
        s.cycleEnd = block.timestamp + 30 days;
        p.totalRevenue = FHE.add(p.totalRevenue, p.monthlyPriceUSD);
        _totalMarketRevenue = FHE.add(_totalMarketRevenue, p.monthlyPriceUSD);
        FHE.allowThis(s.dataUsedMB);
        FHE.allowThis(s.dataRemainingMB);
        FHE.allow(s.dataRemainingMB, user);
        FHE.allowThis(s.totalSpentUSD);
        FHE.allowThis(p.totalRevenue);
        FHE.allowThis(_totalMarketRevenue);
        emit BillGenerated(user);
    }

    function cancelSubscription() external {
        subscriptions[msg.sender].active = false;
        emit PlanCancelled(msg.sender);
    }

    function allowSubscriptionData(address user, address viewer) external {
        require(isOperator[msg.sender] || msg.sender == user, "Unauthorized");
        FHE.allow(subscriptions[user].dataRemainingMB, viewer);
        FHE.allow(subscriptions[user].billAmountUSD, viewer);
        FHE.allow(subscriptions[user].totalSpentUSD, viewer);
    }
}
