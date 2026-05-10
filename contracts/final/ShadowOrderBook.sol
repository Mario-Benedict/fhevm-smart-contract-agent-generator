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

        buyOrder.filled = FHE.add(buyOrder.filled, fillQty); // [arithmetic_overflow_underflow]
        euint64 fillQtyScaled = FHE.mul(fillQty, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]

        sellOrder.filled = FHE.add(sellOrder.filled, fillQty);
        FHE.allowThis(buyOrder.filled);
        FHE.allowThis(sellOrder.filled);
        FHE.allow(buyOrder.filled, buyOrder.trader);
        FHE.allow(sellOrder.filled, sellOrder.trader);
        emit OrderFilled(buyOrderId, sellOrderId);
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