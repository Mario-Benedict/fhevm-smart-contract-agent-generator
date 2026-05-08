// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialCryptocurrencyExchangeOrderBook
/// @notice Dark pool order book for institutional crypto trading where order sizes,
///         prices, and trader identities are shielded until execution.
contract ConfidentialCryptocurrencyExchangeOrderBook is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum OrderSide { BUY, SELL }
    enum OrderType { MARKET, LIMIT, STOP_LIMIT, ICEBERG }
    enum OrderStatus { OPEN, FILLED, PARTIAL, CANCELLED, EXPIRED }

    struct TradingPair {
        string baseAsset;
        string quoteAsset;
        euint64 lastPriceUSD;          // encrypted last traded price
        euint64 bidDepth;              // encrypted total bid liquidity
        euint64 askDepth;              // encrypted total ask liquidity
        euint64 volume24hUSD;          // encrypted 24h volume
        euint32 tickSizeBps;           // encrypted minimum price increment
        bool active;
    }

    struct Order {
        uint256 pairId;
        address trader;
        OrderSide side;
        OrderType orderType;
        euint64 quantity;              // encrypted order size
        euint64 limitPrice;            // encrypted limit price (0 for market)
        euint64 filledQuantity;        // encrypted amount executed
        euint64 averageFillPrice;      // encrypted avg execution price
        euint64 feesPaid;              // encrypted trading fees
        uint256 submissionTime;
        uint256 expiryTime;
        OrderStatus status;
    }

    struct TraderAccount {
        euint64 baseBalance;           // encrypted base asset balance
        euint64 quoteBalance;          // encrypted quote asset balance
        euint64 totalTradingVolume;    // encrypted lifetime volume
        euint64 totalFeesPaid;         // encrypted total fees
        euint32 tradeCount;            // encrypted number of trades
        euint8  tierLevel;             // encrypted VIP tier 0-5
        bool kycVerified;
        bool institutionalAccount;
    }

    struct TradeExecution {
        uint256 buyOrderId;
        uint256 sellOrderId;
        euint64 executedQuantity;      // encrypted
        euint64 executionPrice;        // encrypted
        euint64 buyerFee;              // encrypted
        euint64 sellerFee;             // encrypted
        uint256 executionTimestamp;
    }

    mapping(uint256 => TradingPair) private pairs;
    mapping(uint256 => Order) private orders;
    mapping(address => TraderAccount) private traders;
    mapping(uint256 => TradeExecution) private executions;
    mapping(address => bool) public isMarketOperator;
    mapping(address => bool) public isComplianceOfficer;
    uint256 public pairCount;
    uint256 public orderCount;
    uint256 public executionCount;
    euint64 private _exchangeTotalVolume;
    euint64 private _exchangeTotalFees;
    euint32 private _makerFeeBps;
    euint32 private _takerFeeBps;

    event PairCreated(uint256 indexed pairId, string base, string quote);
    event OrderSubmitted(uint256 indexed orderId, OrderSide side);
    event OrderCancelled(uint256 indexed orderId);
    event TradeExecuted(uint256 indexed execId, uint256 buyId, uint256 sellId);
    event TraderRegistered(address indexed trader);

    constructor(uint32 makerBps, uint32 takerBps) Ownable(msg.sender) {
        _makerFeeBps = FHE.asEuint32(makerBps);
        _takerFeeBps = FHE.asEuint32(takerBps);
        _exchangeTotalVolume = FHE.asEuint64(0);
        _exchangeTotalFees = FHE.asEuint64(0);
        FHE.allowThis(_makerFeeBps);
        FHE.allowThis(_takerFeeBps);
        FHE.allowThis(_exchangeTotalVolume);
        FHE.allowThis(_exchangeTotalFees);
        isMarketOperator[msg.sender] = true;
        isComplianceOfficer[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isMarketOperator[op] = true; }

    function createPair(
        string calldata base, string calldata quote,
        externalEuint32 encTickSize, bytes calldata tsProof
    ) external returns (uint256 pairId) {
        require(isMarketOperator[msg.sender], "Not operator");
        euint32 tick = FHE.fromExternal(encTickSize, tsProof);
        pairId = pairCount++;
        pairs[pairId].baseAsset = base;
        pairs[pairId].quoteAsset = quote;
        pairs[pairId].lastPriceUSD = FHE.asEuint64(0);
        pairs[pairId].bidDepth = FHE.asEuint64(0);
        pairs[pairId].askDepth = FHE.asEuint64(0);
        pairs[pairId].volume24hUSD = FHE.asEuint64(0);
        pairs[pairId].tickSizeBps = tick;
        pairs[pairId].active = true;
        FHE.allowThis(pairs[pairId].lastPriceUSD);
        FHE.allowThis(pairs[pairId].bidDepth);
        FHE.allowThis(pairs[pairId].askDepth);
        FHE.allowThis(pairs[pairId].volume24hUSD);
        FHE.allowThis(pairs[pairId].tickSizeBps);
        emit PairCreated(pairId, base, quote);
    }

    function registerTrader(bool institutional) external {
        require(!traders[msg.sender].kycVerified, "Already registered");
        traders[msg.sender] = TraderAccount({
            baseBalance: FHE.asEuint64(0),
            quoteBalance: FHE.asEuint64(0),
            totalTradingVolume: FHE.asEuint64(0),
            totalFeesPaid: FHE.asEuint64(0),
            tradeCount: FHE.asEuint32(0),
            tierLevel: FHE.asEuint8(0),
            kycVerified: true,
            institutionalAccount: institutional
        });
        FHE.allowThis(traders[msg.sender].baseBalance);
        FHE.allow(traders[msg.sender].baseBalance, msg.sender);
        FHE.allowThis(traders[msg.sender].quoteBalance);
        FHE.allow(traders[msg.sender].quoteBalance, msg.sender);
        FHE.allowThis(traders[msg.sender].totalTradingVolume);
        FHE.allow(traders[msg.sender].totalTradingVolume, msg.sender);
        FHE.allowThis(traders[msg.sender].totalFeesPaid);
        FHE.allowThis(traders[msg.sender].tradeCount);
        FHE.allowThis(traders[msg.sender].tierLevel);
        emit TraderRegistered(msg.sender);
    }

    function depositFunds(
        bool isBase,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        require(traders[msg.sender].kycVerified, "Not registered");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        if (isBase) {
            traders[msg.sender].baseBalance = FHE.add(traders[msg.sender].baseBalance, amount);
            FHE.allowThis(traders[msg.sender].baseBalance);
            FHE.allow(traders[msg.sender].baseBalance, msg.sender);
        } else {
            traders[msg.sender].quoteBalance = FHE.add(traders[msg.sender].quoteBalance, amount);
            FHE.allowThis(traders[msg.sender].quoteBalance);
            FHE.allow(traders[msg.sender].quoteBalance, msg.sender);
        }
    }

    function submitOrder(
        uint256 pairId,
        OrderSide side,
        OrderType orderType,
        externalEuint64 encQty,   bytes calldata qProof,
        externalEuint64 encPrice, bytes calldata pProof,
        uint256 expiryDuration
    ) external nonReentrant returns (uint256 orderId) {
        require(pairs[pairId].active, "Pair inactive");
        require(traders[msg.sender].kycVerified, "Not registered");
        euint64 qty   = FHE.fromExternal(encQty, qProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        orderId = orderCount++;
        orders[orderId] = Order({
            pairId: pairId,
            trader: msg.sender,
            side: side,
            orderType: orderType,
            quantity: qty,
            limitPrice: price,
            filledQuantity: FHE.asEuint64(0),
            averageFillPrice: FHE.asEuint64(0),
            feesPaid: FHE.asEuint64(0),
            submissionTime: block.timestamp,
            expiryTime: block.timestamp + expiryDuration,
            status: OrderStatus.OPEN
        });
        // Update pair depth
        if (side == OrderSide.BUY) {
            pairs[pairId].bidDepth = FHE.add(pairs[pairId].bidDepth, qty);
            FHE.allowThis(pairs[pairId].bidDepth);
        } else {
            pairs[pairId].askDepth = FHE.add(pairs[pairId].askDepth, qty);
            FHE.allowThis(pairs[pairId].askDepth);
        }
        FHE.allowThis(orders[orderId].quantity);
        FHE.allow(orders[orderId].quantity, msg.sender);
        FHE.allowThis(orders[orderId].limitPrice);
        FHE.allow(orders[orderId].limitPrice, msg.sender);
        FHE.allowThis(orders[orderId].filledQuantity);
        FHE.allow(orders[orderId].filledQuantity, msg.sender);
        FHE.allowThis(orders[orderId].feesPaid);
        emit OrderSubmitted(orderId, side);
    }

    function matchOrders(
        uint256 buyOrderId,
        uint256 sellOrderId,
        externalEuint64 encExecQty,   bytes calldata eqProof,
        externalEuint64 encExecPrice, bytes calldata epProof
    ) external nonReentrant {
        require(isMarketOperator[msg.sender], "Not operator");
        require(orders[buyOrderId].side == OrderSide.BUY, "Not buy order");
        require(orders[sellOrderId].side == OrderSide.SELL, "Not sell order");
        euint64 execQty   = FHE.fromExternal(encExecQty, eqProof);
        euint64 execPrice = FHE.fromExternal(encExecPrice, epProof);
        euint64 buyFee    = FHE.div(FHE.mul(execQty, FHE.asEuint64(uint64(0))), 10000);
        euint64 sellFee   = FHE.div(FHE.mul(execQty, FHE.asEuint64(uint64(0))), 10000);
        uint256 execId = executionCount++;
        executions[execId] = TradeExecution({
            buyOrderId: buyOrderId,
            sellOrderId: sellOrderId,
            executedQuantity: execQty,
            executionPrice: execPrice,
            buyerFee: buyFee,
            sellerFee: sellFee,
            executionTimestamp: block.timestamp
        });
        orders[buyOrderId].filledQuantity = FHE.add(orders[buyOrderId].filledQuantity, execQty);
        orders[sellOrderId].filledQuantity = FHE.add(orders[sellOrderId].filledQuantity, execQty);
        orders[buyOrderId].status = OrderStatus.FILLED;
        orders[sellOrderId].status = OrderStatus.FILLED;
        _exchangeTotalVolume = FHE.add(_exchangeTotalVolume, execQty);
        _exchangeTotalFees = FHE.add(_exchangeTotalFees, FHE.add(buyFee, sellFee));
        // Update pair last price
        pairs[orders[buyOrderId].pairId].lastPriceUSD = execPrice;
        pairs[orders[buyOrderId].pairId].volume24hUSD = FHE.add(
            pairs[orders[buyOrderId].pairId].volume24hUSD, execQty
        );
        FHE.allowThis(executions[execId].executedQuantity);
        FHE.allowThis(executions[execId].executionPrice);
        FHE.allowThis(orders[buyOrderId].filledQuantity);
        FHE.allowThis(orders[sellOrderId].filledQuantity);
        FHE.allowThis(_exchangeTotalVolume);
        FHE.allowThis(_exchangeTotalFees);
        FHE.allowThis(pairs[orders[buyOrderId].pairId].lastPriceUSD);
        FHE.allowThis(pairs[orders[buyOrderId].pairId].volume24hUSD);
        emit TradeExecuted(execId, buyOrderId, sellOrderId);
    }

    function cancelOrder(uint256 orderId) external {
        require(orders[orderId].trader == msg.sender, "Not your order");
        require(orders[orderId].status == OrderStatus.OPEN, "Order not open");
        orders[orderId].status = OrderStatus.CANCELLED;
        emit OrderCancelled(orderId);
    }

    function allowExchangeStats(address viewer) external onlyOwner {
        FHE.allow(_exchangeTotalVolume, viewer);
        FHE.allow(_exchangeTotalFees, viewer);
    }
}
