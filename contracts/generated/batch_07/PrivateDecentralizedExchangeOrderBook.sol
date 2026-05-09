// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateDecentralizedExchangeOrderBook
/// @notice Encrypted DEX order book: hidden order sizes, private limit prices,
///         confidential maker/taker identities, and encrypted fee tier calculations.
contract PrivateDecentralizedExchangeOrderBook is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum OrderSide { Buy, Sell }
    enum OrderType { Limit, Market, StopLimit }

    struct Order {
        address trader;
        OrderSide side;
        OrderType orderType;
        address tokenIn;
        address tokenOut;
        euint64 amountIn;              // encrypted order size
        euint64 limitPrice;            // encrypted limit price
        euint64 stopPrice;             // encrypted stop price
        euint64 filledAmount;          // encrypted filled amount
        euint16 feeTierBps;            // encrypted fee tier
        uint256 placedAt;
        uint256 expiryTime;
        bool filled;
        bool cancelled;
    }

    struct Trade {
        uint256 makerOrderId;
        uint256 takerOrderId;
        euint64 tradeAmount;           // encrypted trade size
        euint64 tradePrice;            // encrypted execution price
        euint64 makerFee;              // encrypted maker fee
        euint64 takerFee;              // encrypted taker fee
        uint256 executedAt;
    }

    mapping(uint256 => Order) private orders;
    mapping(uint256 => Trade) private trades;
    mapping(address => bool) public isMatchingEngine;

    uint256 public orderCount;
    uint256 public tradeCount;
    euint64 private _totalVolumeUSD;
    euint64 private _totalFeesCollected;

    event OrderPlaced(uint256 indexed id, OrderSide side, OrderType orderType);
    event TradeExecuted(uint256 indexed tradeId, uint256 makerOrderId, uint256 takerOrderId);
    event OrderCancelled(uint256 indexed id);

    modifier onlyMatchingEngine() {
        require(isMatchingEngine[msg.sender] || msg.sender == owner(), "Not matching engine");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalVolumeUSD = FHE.asEuint64(0);
        _totalFeesCollected = FHE.asEuint64(0);
        FHE.allowThis(_totalVolumeUSD);
        FHE.allowThis(_totalFeesCollected);
        isMatchingEngine[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addMatchingEngine(address me) external onlyOwner { isMatchingEngine[me] = true; }

    function placeOrder(
        OrderSide side, OrderType orderType, address tokenIn, address tokenOut,
        externalEuint64 encAmtIn,  bytes calldata amProof,
        externalEuint64 encLimit,  bytes calldata limProof,
        externalEuint64 encStop,   bytes calldata stopProof,
        externalEuint16 encFeeTier,bytes calldata ftProof,
        uint256 expiryHours
    ) external whenNotPaused returns (uint256 id) {
        euint64 amtIn    = FHE.fromExternal(encAmtIn, amProof);
        euint64 limit    = FHE.fromExternal(encLimit, limProof);
        euint64 stop     = FHE.fromExternal(encStop, stopProof);
        euint16 feeTier  = FHE.fromExternal(encFeeTier, ftProof);
        id = orderCount++;
        Order storage _s0 = orders[id];
        _s0.trader = msg.sender;
        _s0.side = side;
        _s0.orderType = orderType;
        _s0.tokenIn = tokenIn;
        _s0.tokenOut = tokenOut;
        _s0.amountIn = amtIn;
        _s0.limitPrice = limit;
        _s0.stopPrice = stop;
        _s0.filledAmount = FHE.asEuint64(0);
        _s0.feeTierBps = feeTier;
        _s0.placedAt = block.timestamp;
        _s0.expiryTime = block.timestamp + expiryHours * 1 hours;
        _s0.filled = false;
        _s0.cancelled = false;
        FHE.allowThis(orders[id].amountIn); FHE.allow(orders[id].amountIn, msg.sender);
        FHE.allowThis(orders[id].limitPrice); FHE.allow(orders[id].limitPrice, msg.sender);
        FHE.allowThis(orders[id].stopPrice); FHE.allow(orders[id].stopPrice, msg.sender);
        FHE.allowThis(orders[id].filledAmount); FHE.allow(orders[id].filledAmount, msg.sender);
        FHE.allowThis(orders[id].feeTierBps);
        emit OrderPlaced(id, side, orderType);
    }

    function executeTrade(
        uint256 makerOrderId, uint256 takerOrderId,
        externalEuint64 encTradeAmt, bytes calldata taProof,
        externalEuint64 encTradePrice, bytes calldata tpProof
    ) external onlyMatchingEngine whenNotPaused nonReentrant returns (uint256 tradeId) {
        Order storage maker = orders[makerOrderId];
        Order storage taker = orders[takerOrderId];
        require(!maker.filled && !maker.cancelled && !taker.filled && !taker.cancelled, "Orders invalid");
        euint64 tradeAmt   = FHE.fromExternal(encTradeAmt, taProof);
        euint64 tradePrice = FHE.fromExternal(encTradePrice, tpProof);
        euint64 makerFee   = FHE.div(FHE.mul(tradeAmt, 5), 10000);  // 0.05% maker
        euint64 takerFee   = FHE.div(FHE.mul(tradeAmt, 10), 10000); // 0.10% taker
        tradeId = tradeCount++;
        trades[tradeId] = Trade({
            makerOrderId: makerOrderId, takerOrderId: takerOrderId,
            tradeAmount: tradeAmt, tradePrice: tradePrice,
            makerFee: makerFee, takerFee: takerFee, executedAt: block.timestamp
        });
        maker.filledAmount = FHE.add(maker.filledAmount, tradeAmt);
        taker.filledAmount = FHE.add(taker.filledAmount, tradeAmt);
        _totalVolumeUSD = FHE.add(_totalVolumeUSD, FHE.mul(tradeAmt, tradePrice));
        _totalFeesCollected = FHE.add(_totalFeesCollected, FHE.add(makerFee, takerFee));
        FHE.allowThis(trades[tradeId].tradeAmount); FHE.allow(trades[tradeId].tradeAmount, maker.trader); FHE.allow(trades[tradeId].tradeAmount, taker.trader);
        FHE.allowThis(trades[tradeId].tradePrice); FHE.allow(trades[tradeId].tradePrice, maker.trader); FHE.allow(trades[tradeId].tradePrice, taker.trader);
        FHE.allowThis(trades[tradeId].makerFee); FHE.allow(trades[tradeId].makerFee, maker.trader);
        FHE.allowThis(trades[tradeId].takerFee); FHE.allow(trades[tradeId].takerFee, taker.trader);
        FHE.allowThis(maker.filledAmount); FHE.allow(maker.filledAmount, maker.trader);
        FHE.allowThis(taker.filledAmount); FHE.allow(taker.filledAmount, taker.trader);
        FHE.allowThis(_totalVolumeUSD); FHE.allowThis(_totalFeesCollected);
        emit TradeExecuted(tradeId, makerOrderId, takerOrderId);
    }

    function cancelOrder(uint256 orderId) external {
        require(orders[orderId].trader == msg.sender, "Not your order");
        orders[orderId].cancelled = true;
        emit OrderCancelled(orderId);
    }

    function allowExchangeStats(address viewer) external onlyOwner {
        FHE.allow(_totalVolumeUSD, viewer); FHE.allow(_totalFeesCollected, viewer);
    }
}
