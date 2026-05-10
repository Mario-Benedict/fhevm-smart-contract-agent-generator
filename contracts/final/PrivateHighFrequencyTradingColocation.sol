// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateHighFrequencyTradingColocation
/// @notice Encrypted HFT colocation service pricing: hidden latency measurements per slot,
///         confidential order flow revenue sharing, private cross-connect fee schedules,
///         and encrypted market data subscription charges.
contract PrivateHighFrequencyTradingColocation is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ColoTier { Tier1Nano, Tier2Micro, Tier3Standard, Tier4Premium, Tier5UltraLow }
    enum ExchangeConnectivity { NYSE, NASDAQ, CBOE, CME, ICE, Eurex, LSE }

    struct ColoSubscription {
        address hftFirm;
        ColoTier tier;
        ExchangeConnectivity primaryExchange;
        string rackRef;
        euint64 monthlyRackFeeUSD;     // encrypted monthly rack fee
        euint64 orderFlowShareUSD;     // encrypted order flow rebate
        euint64 crossConnectFeeUSD;    // encrypted cross-connect fee
        euint64 marketDataFeeUSD;      // encrypted market data fee
        euint32 latencyMicroseconds;   // encrypted measured latency
        euint64 totalMonthlyBillUSD;   // encrypted total bill
        uint256 subscriptionStart;
        uint256 subscriptionEnd;
        bool active;
    }

    mapping(uint256 => ColoSubscription) private subscriptions;
    mapping(address => bool) public isExchangeAdmin;

    uint256 public subscriptionCount;
    euint64 private _totalColoRevenueUSD;
    euint64 private _totalOrderFlowSharedUSD;

    event ColoSubscribed(uint256 indexed id, ColoTier tier, address hftFirm);
    event MonthlyBillGenerated(uint256 indexed id, uint256 billedAt);

    modifier onlyExchangeAdmin() {
        require(isExchangeAdmin[msg.sender] || msg.sender == owner(), "Not exchange admin");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalColoRevenueUSD = FHE.asEuint64(0);
        _totalOrderFlowSharedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalColoRevenueUSD);
        FHE.allowThis(_totalOrderFlowSharedUSD);
        isExchangeAdmin[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addExchangeAdmin(address a) external onlyOwner { isExchangeAdmin[a] = true; }

    function createColoSubscription(
        address hftFirm, ColoTier tier, ExchangeConnectivity primaryExchange, string calldata rackRef,
        externalEuint64 encRackFee, bytes calldata rfProof,
        externalEuint64 encCrossConnect, bytes calldata ccProof,
        externalEuint64 encMarketData, bytes calldata mdProof,
        externalEuint32 encLatency, bytes calldata latProof,
        uint256 durationMonths
    ) external onlyExchangeAdmin whenNotPaused returns (uint256 id) {
        euint64 rackFee = FHE.fromExternal(encRackFee, rfProof);
        euint64 crossConnect = FHE.fromExternal(encCrossConnect, ccProof);
        euint64 marketData = FHE.fromExternal(encMarketData, mdProof);
        euint32 latency = FHE.fromExternal(encLatency, latProof);
        euint64 totalBill = FHE.add(FHE.add(rackFee, crossConnect), marketData); // [arithmetic_overflow_underflow]
        euint64 marketDataScaled = FHE.mul(marketData, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        id = subscriptionCount++;
        ColoSubscription storage _s0 = subscriptions[id];
        _s0.hftFirm = hftFirm;
        _s0.tier = tier;
        _s0.primaryExchange = primaryExchange;
        _s0.rackRef = rackRef;
        _s0.monthlyRackFeeUSD = rackFee;
        _s0.orderFlowShareUSD = FHE.asEuint64(0);
        _s0.crossConnectFeeUSD = crossConnect;
        _s0.marketDataFeeUSD = marketData;
        _s0.latencyMicroseconds = latency;
        _s0.totalMonthlyBillUSD = totalBill;
        _s0.subscriptionStart = block.timestamp;
        _s0.subscriptionEnd = block.timestamp + durationMonths * 30 days;
        _s0.active = true;
        _totalColoRevenueUSD = FHE.add(_totalColoRevenueUSD, totalBill);
        FHE.allowThis(subscriptions[id].monthlyRackFeeUSD); FHE.allow(subscriptions[id].monthlyRackFeeUSD, hftFirm);
        FHE.allowThis(subscriptions[id].orderFlowShareUSD); FHE.allow(subscriptions[id].orderFlowShareUSD, hftFirm);
        FHE.allowThis(subscriptions[id].crossConnectFeeUSD); FHE.allow(subscriptions[id].crossConnectFeeUSD, hftFirm);
        FHE.allowThis(subscriptions[id].marketDataFeeUSD); FHE.allow(subscriptions[id].marketDataFeeUSD, hftFirm);
        FHE.allowThis(subscriptions[id].latencyMicroseconds); FHE.allow(subscriptions[id].latencyMicroseconds, hftFirm);
        FHE.allowThis(subscriptions[id].totalMonthlyBillUSD); FHE.allow(subscriptions[id].totalMonthlyBillUSD, hftFirm);
        FHE.allowThis(_totalColoRevenueUSD);
        emit ColoSubscribed(id, tier, hftFirm);
    }

    function updateOrderFlowShare(
        uint256 subscriptionId,
        externalEuint64 encOrderFlowShare, bytes calldata proof
    ) external onlyExchangeAdmin {
        ColoSubscription storage s = subscriptions[subscriptionId];
        euint64 orderFlowShare = FHE.fromExternal(encOrderFlowShare, proof);
        s.orderFlowShareUSD = orderFlowShare;
        _totalOrderFlowSharedUSD = FHE.add(_totalOrderFlowSharedUSD, orderFlowShare);
        FHE.allowThis(s.orderFlowShareUSD); FHE.allow(s.orderFlowShareUSD, s.hftFirm);
        FHE.allowThis(_totalOrderFlowSharedUSD);
        emit MonthlyBillGenerated(subscriptionId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalColoRevenueUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalColoRevenueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalOrderFlowSharedUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalOrderFlowSharedUSD, viewer);
    }
}
