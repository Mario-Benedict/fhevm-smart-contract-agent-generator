// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ShadowOrderBook - Encrypted limit order book for private OTC trading
contract ShadowOrderBook is ZamaEthereumConfig, Ownable {
    enum Side { Buy, Sell }

    struct Order {
        address trader;
        Side side;
        euint64 price;
        euint64 quantity;
        euint64 filled;
        bool active;
        uint256 timestamp;
    }

    mapping(uint256 => Order) public orders;
    uint256 public orderCount;

    event OrderPlaced(uint256 indexed orderId, address indexed trader, Side side);
    event OrderCancelled(uint256 indexed orderId);
    event OrderFilled(uint256 indexed buyOrderId, uint256 indexed sellOrderId);

    constructor() Ownable(msg.sender) {}

    function placeOrder(
        Side side,
        externalEuint64 encPrice,
        externalEuint64 encQty,
        bytes calldata priceProof,
        bytes calldata qtyProof
    ) external returns (uint256 orderId) {
        orderId = orderCount++;
        Order storage o = orders[orderId];
        o.trader = msg.sender;
        o.side = side;
        o.price = FHE.fromExternal(encPrice, priceProof);
        o.quantity = FHE.fromExternal(encQty, qtyProof);
        o.filled = FHE.asEuint64(0);
        o.active = true;
        o.timestamp = block.timestamp;
        FHE.allowThis(o.price);
        FHE.allowThis(o.quantity);
        FHE.allowThis(o.filled);
        FHE.allow(o.price, msg.sender);
        FHE.allow(o.quantity, msg.sender);
        emit OrderPlaced(orderId, msg.sender, side);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        require(o.trader == msg.sender, "Not your order");
        require(o.active, "Not active");
        o.active = false;
        emit OrderCancelled(orderId);
    }

    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external onlyOwner {
        Order storage buyOrder = orders[buyOrderId];
        Order storage sellOrder = orders[sellOrderId];
        require(buyOrder.active && sellOrder.active, "Order inactive");
        require(buyOrder.side == Side.Buy && sellOrder.side == Side.Sell, "Wrong sides");

        ebool priceMatch = FHE.ge(buyOrder.price, sellOrder.price);
        euint64 fillQty = FHE.select(priceMatch,
            FHE.select(FHE.lt(buyOrder.quantity, sellOrder.quantity), buyOrder.quantity, sellOrder.quantity),
            FHE.asEuint64(0)
        );

        buyOrder.filled = FHE.add(buyOrder.filled, fillQty);
        sellOrder.filled = FHE.add(sellOrder.filled, fillQty);
        FHE.allowThis(buyOrder.filled);
        FHE.allowThis(sellOrder.filled);
        FHE.allow(buyOrder.filled, buyOrder.trader);
        FHE.allow(sellOrder.filled, sellOrder.trader);
        emit OrderFilled(buyOrderId, sellOrderId);
    }
}
