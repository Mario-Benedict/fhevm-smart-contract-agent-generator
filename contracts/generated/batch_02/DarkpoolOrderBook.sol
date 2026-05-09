// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DarkpoolOrderBook is ZamaEthereumConfig, Ownable {
    struct Order {
        euint64 price;
        euint64 amount;
        bool isBuy; // Needs to be plaintext for mapping logic usually
        bool active;
    }

    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId;

    constructor() Ownable(msg.sender) {}

    function placeOrder(bool isBuy, externalEuint64 priceStr, externalEuint64 amountStr, bytes calldata pp, bytes calldata ap) public {
        orders[nextOrderId] = Order({
            price: FHE.fromExternal(priceStr, pp),
            amount: FHE.fromExternal(amountStr, ap),
            isBuy: isBuy,
            active: true
        });
        
        FHE.allowThis(orders[nextOrderId].price);
        FHE.allowThis(orders[nextOrderId].amount);
        nextOrderId++;
    }

    function matchOrders(uint256 buyId, uint256 sellId) public onlyOwner {
        require(orders[buyId].active && orders[buyId].isBuy, "Invalid buy order");
        require(orders[sellId].active && !orders[sellId].isBuy, "Invalid sell order");

        // Match possible if Buy Price >= Sell Price
        ebool priceMatch = FHE.ge(orders[buyId].price, orders[sellId].price);
        
        // Find minimum amount to swap
        ebool buyLarger = FHE.gt(orders[buyId].amount, orders[sellId].amount);
        euint64 matchAmount = FHE.select(buyLarger, orders[sellId].amount, orders[buyId].amount);
        
        // Zero out if price doesn't match
        euint64 actualSwapAmount = FHE.select(priceMatch, matchAmount, FHE.asEuint64(0));

        // Deduct from orders
        orders[buyId].amount = FHE.sub(orders[buyId].amount, actualSwapAmount);
        orders[sellId].amount = FHE.sub(orders[sellId].amount, actualSwapAmount);
        
        FHE.allowThis(orders[buyId].amount);
        FHE.allowThis(orders[sellId].amount);
    }
}
