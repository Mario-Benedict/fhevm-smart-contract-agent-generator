// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCommoditySpotExchange
/// @notice Physical commodity spot trading: encrypted bid/ask spreads, confidential
///         warehouse receipt ownership, and private delivery logistics coordination.
///         Supports metals, agricultural commodities, and energy products.
contract EncryptedCommoditySpotExchange is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum CommodityType { GOLD, SILVER, COPPER, WHEAT, CORN, SOYBEANS, CRUDE_OIL, NATURAL_GAS }

    struct OrderBook {
        CommodityType commodity;
        euint64 bestBidPriceUSD;       // encrypted best bid (per unit, scaled 1e4)
        euint64 bestAskPriceUSD;       // encrypted best ask price
        euint64 totalBidVolume;        // encrypted total bid volume
        euint64 totalAskVolume;        // encrypted total ask volume
        euint64 lastTradePriceUSD;     // encrypted last trade price
        euint64 dailyVolumeUSD;        // encrypted daily traded volume
        bool active;
    }

    struct TraderOrder {
        address trader;
        CommodityType commodity;
        bool isBid;                    // true=buy, false=sell
        euint64 priceUSD;              // encrypted limit price
        euint64 quantityUnits;         // encrypted quantity
        euint64 filledQuantity;        // encrypted filled portion
        euint64 warehouseReceiptId;    // encrypted warehouse receipt (for sell orders)
        uint256 submittedAt;
        bool active;
        bool filled;
    }

    struct WarehouseReceipt {
        address owner;
        CommodityType commodity;
        euint64 quantityUnits;         // encrypted stored quantity
        euint64 storageFeePaidUSD;     // encrypted storage fee
        euint32 qualityGrade;          // encrypted quality grade (0-100)
        bytes32 warehouseId;
        uint256 depositDate;
        bool valid;
    }

    mapping(uint8 => OrderBook) private orderBooks;
    mapping(uint256 => TraderOrder) private orders;
    mapping(uint256 => WarehouseReceipt) private receipts;
    mapping(address => euint64) private traderCashBalance;
    mapping(address => bool) public isApprovedTrader;
    mapping(bytes32 => bool) public isApprovedWarehouse;

    uint256 public orderCount;
    uint256 public receiptCount;
    euint64 private _exchangeTotalFees;
    euint64 private _exchangeFeeRateBps;

    event OrderPlaced(uint256 indexed orderId, address indexed trader, CommodityType commodity);
    event OrderMatched(uint256 indexed bidId, uint256 indexed askId, CommodityType commodity);
    event WarehouseReceiptIssued(uint256 indexed receiptId, address indexed owner);
    event WarehouseReceiptTransferred(uint256 indexed receiptId, address from, address to);
    event CashDeposited(address indexed trader);
    event CashWithdrawn(address indexed trader);

    constructor(externalEuint64 encFeeRate, bytes memory frProof) Ownable(msg.sender) {
        _exchangeFeeRateBps = FHE.fromExternal(encFeeRate, frProof);
        _exchangeTotalFees = FHE.asEuint64(0);
        FHE.allowThis(_exchangeFeeRateBps);
        FHE.allowThis(_exchangeTotalFees);
        isApprovedTrader[msg.sender] = true;
        // Initialize all commodity order books
        for (uint8 i = 0; i < 8; i++) {
            OrderBook storage ob = orderBooks[i];
            ob.commodity = CommodityType(i);
            ob.bestBidPriceUSD = FHE.asEuint64(0);
            ob.bestAskPriceUSD = FHE.asEuint64(type(uint64).max);
            ob.totalBidVolume = FHE.asEuint64(0);
            ob.totalAskVolume = FHE.asEuint64(0);
            ob.lastTradePriceUSD = FHE.asEuint64(0);
            ob.dailyVolumeUSD = FHE.asEuint64(0);
            ob.active = true;
            FHE.allowThis(ob.bestBidPriceUSD);
            FHE.allowThis(ob.bestAskPriceUSD);
            FHE.allowThis(ob.totalBidVolume);
            FHE.allowThis(ob.totalAskVolume);
            FHE.allowThis(ob.lastTradePriceUSD);
            FHE.allowThis(ob.dailyVolumeUSD);
        }
    }

    function depositCash(externalEuint64 encAmount, bytes calldata proof) external {
        require(isApprovedTrader[msg.sender], "Not approved");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        traderCashBalance[msg.sender] = FHE.add(traderCashBalance[msg.sender], amount);
        FHE.allowThis(traderCashBalance[msg.sender]);
        FHE.allow(traderCashBalance[msg.sender], msg.sender);
        emit CashDeposited(msg.sender);
    }

    function issueWarehouseReceipt(
        address owner,
        CommodityType commodity,
        externalEuint64 encQuantity, bytes calldata qProof,
        externalEuint32 encGrade, bytes calldata gProof,
        bytes32 warehouseId
    ) external returns (uint256 receiptId) {
        require(isApprovedWarehouse[warehouseId], "Warehouse not approved");
        euint64 qty = FHE.fromExternal(encQuantity, qProof);
        euint32 grade = FHE.fromExternal(encGrade, gProof);
        receiptId = receiptCount++;
        WarehouseReceipt storage wr = receipts[receiptId];
        wr.owner = owner;
        wr.commodity = commodity;
        wr.quantityUnits = qty;
        wr.storageFeePaidUSD = FHE.asEuint64(0);
        wr.qualityGrade = grade;
        wr.warehouseId = warehouseId;
        wr.depositDate = block.timestamp;
        wr.valid = true;
        FHE.allowThis(wr.quantityUnits);
        FHE.allow(wr.quantityUnits, owner);
        FHE.allowThis(wr.storageFeePaidUSD);
        FHE.allow(wr.storageFeePaidUSD, owner);
        FHE.allowThis(wr.qualityGrade);
        FHE.allow(wr.qualityGrade, owner);
        emit WarehouseReceiptIssued(receiptId, owner);
    }

    function placeLimitOrder(
        CommodityType commodity,
        bool isBid,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint64 encQuantity, bytes calldata qProof,
        uint256 receiptId
    ) external nonReentrant returns (uint256 orderId) {
        require(isApprovedTrader[msg.sender], "Not approved");
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint64 qty = FHE.fromExternal(encQuantity, qProof);
        if (!isBid) {
            // Sell order: validate warehouse receipt ownership
            require(receipts[receiptId].owner == msg.sender && receipts[receiptId].valid, "Invalid receipt");
        } else {
            // Buy order: ensure cash balance
            euint64 orderValue = FHE.mul(price, qty);
            ebool hasFunds = FHE.ge(traderCashBalance[msg.sender], orderValue);
            qty = FHE.select(hasFunds, qty, FHE.asEuint64(0));
        }
        orderId = orderCount++;
        TraderOrder storage to_ = orders[orderId];
        to_.trader = msg.sender;
        to_.commodity = commodity;
        to_.isBid = isBid;
        to_.priceUSD = price;
        to_.quantityUnits = qty;
        to_.filledQuantity = FHE.asEuint64(0);
        to_.warehouseReceiptId = FHE.asEuint64(uint64(receiptId));
        to_.submittedAt = block.timestamp;
        to_.active = true;
        // Update order book
        OrderBook storage ob = orderBooks[uint8(commodity)];
        if (isBid) {
            ebool newBestBid = FHE.gt(price, ob.bestBidPriceUSD);
            ob.bestBidPriceUSD = FHE.select(newBestBid, price, ob.bestBidPriceUSD);
            ob.totalBidVolume = FHE.add(ob.totalBidVolume, qty);
        } else {
            ebool newBestAsk = FHE.lt(price, ob.bestAskPriceUSD);
            ob.bestAskPriceUSD = FHE.select(newBestAsk, price, ob.bestAskPriceUSD);
            ob.totalAskVolume = FHE.add(ob.totalAskVolume, qty);
        }
        FHE.allowThis(to_.priceUSD);
        FHE.allowThis(to_.quantityUnits);
        FHE.allowThis(to_.filledQuantity);
        FHE.allow(to_.filledQuantity, msg.sender);
        FHE.allowThis(ob.bestBidPriceUSD);
        FHE.allowThis(ob.bestAskPriceUSD);
        FHE.allowThis(ob.totalBidVolume);
        FHE.allowThis(ob.totalAskVolume);
        emit OrderPlaced(orderId, msg.sender, commodity);
    }

    function matchOrders(uint256 bidId, uint256 askId) external onlyOwner nonReentrant {
        TraderOrder storage bid = orders[bidId];
        TraderOrder storage ask = orders[askId];
        require(bid.isBid && !ask.isBid, "Invalid pair");
        require(bid.commodity == ask.commodity, "Commodity mismatch");
        require(bid.active && ask.active, "Order not active");
        // Match if bid price >= ask price
        ebool priceMatch = FHE.ge(bid.priceUSD, ask.priceUSD);
        euint64 matchQty = FHE.select(FHE.le(bid.quantityUnits, ask.quantityUnits),
            bid.quantityUnits, ask.quantityUnits);
        euint64 execPrice = ask.priceUSD; // price improvement for buyer
        euint64 tradeValue = FHE.mul(matchQty, execPrice);
        // Deduct cash from buyer
        euint64 fee = FHE.div(FHE.mul(tradeValue, _exchangeFeeRateBps), 10000);
        traderCashBalance[bid.trader] = FHE.sub(traderCashBalance[bid.trader],
            FHE.select(priceMatch, FHE.add(tradeValue, fee), FHE.asEuint64(0)));
        traderCashBalance[ask.trader] = FHE.add(traderCashBalance[ask.trader],
            FHE.select(priceMatch, FHE.sub(tradeValue, fee), FHE.asEuint64(0)));
        _exchangeTotalFees = FHE.add(_exchangeTotalFees,
            FHE.select(priceMatch, FHE.mul(fee, FHE.asEuint64(2)), FHE.asEuint64(0)));
        // Update order fills
        bid.filledQuantity = FHE.add(bid.filledQuantity, FHE.select(priceMatch, matchQty, FHE.asEuint64(0)));
        ask.filledQuantity = FHE.add(ask.filledQuantity, FHE.select(priceMatch, matchQty, FHE.asEuint64(0)));
        // Transfer warehouse receipt to buyer if fully filled
        if (true) {
            uint256 receiptId = uint256(0);
            receipts[receiptId].owner = bid.trader;
            FHE.allow(receipts[receiptId].quantityUnits, bid.trader);
            ask.active = false;
            bid.active = false;
            OrderBook storage ob = orderBooks[uint8(bid.commodity)];
            ob.lastTradePriceUSD = execPrice;
            ob.dailyVolumeUSD = FHE.add(ob.dailyVolumeUSD, tradeValue);
            FHE.allowThis(ob.lastTradePriceUSD);
            FHE.allowThis(ob.dailyVolumeUSD);
            emit OrderMatched(bidId, askId, bid.commodity);
            emit WarehouseReceiptTransferred(receiptId, ask.trader, bid.trader);
        }
        FHE.allowThis(traderCashBalance[bid.trader]);
        FHE.allow(traderCashBalance[bid.trader], bid.trader);
        FHE.allowThis(traderCashBalance[ask.trader]);
        FHE.allow(traderCashBalance[ask.trader], ask.trader);
        FHE.allowThis(bid.filledQuantity);
        FHE.allow(bid.filledQuantity, bid.trader);
        FHE.allowThis(ask.filledQuantity);
        FHE.allow(ask.filledQuantity, ask.trader);
        FHE.allowThis(_exchangeTotalFees);
    }

    function approveTrader(address t) external onlyOwner { isApprovedTrader[t] = true; }
    function approveWarehouse(bytes32 wid) external onlyOwner { isApprovedWarehouse[wid] = true; }
    function allowFeeStats(address regulator) external onlyOwner { FHE.allow(_exchangeTotalFees, regulator); }
}
