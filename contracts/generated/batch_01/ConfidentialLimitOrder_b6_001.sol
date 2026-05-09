// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ConfidentialLimitOrder_b6_001 is ZamaEthereumConfig {
    address public oracle;

    struct Order {
        euint64 targetPrice;
        euint64 amountIn;
        ebool isFilled;
        ebool isActive;
    }

    mapping(address => Order) private orders;
    mapping(address => euint64) private balancesOut; // Output token balance

    constructor() {
        oracle = msg.sender;
    }

    function placeOrder(
        externalEuint64 targetPriceStr,
        externalEuint64 amountInStr,
        bytes calldata proofPrice,
        bytes calldata proofAmount
    ) public {
        euint64 tPrice = FHE.fromExternal(targetPriceStr, proofPrice);
        euint64 aIn = FHE.fromExternal(amountInStr, proofAmount);

        orders[msg.sender] = Order({
            targetPrice: tPrice,
            amountIn: aIn,
            isFilled: FHE.asEbool(false),
            isActive: FHE.asEbool(true)
        });

        FHE.allowThis(orders[msg.sender].targetPrice);
        FHE.allowThis(orders[msg.sender].amountIn);
        FHE.allowThis(orders[msg.sender].isFilled);
        FHE.allowThis(orders[msg.sender].isActive);
    }

    function executeOrders(address[] calldata users, externalEuint64 currentPriceStr, bytes calldata proof) public {
        require(msg.sender == oracle, "Only oracle can execute");
        euint64 currentPrice = FHE.fromExternal(currentPriceStr, proof);

        for (uint i = 0; i < users.length; i++) {
            Order storage userOrder = orders[users[i]];
            
            // Execute if currentPrice >= targetPrice and order is active and not filled
            ebool priceMet = FHE.ge(currentPrice, userOrder.targetPrice);
            ebool canExecute = FHE.and(FHE.and(priceMet, userOrder.isActive), FHE.not(userOrder.isFilled));

            // Simplified out calculation: amountIn * currentPrice (assuming 1:1 parity scaling for example)
            euint64 outAmountAssumed = FHE.mul(userOrder.amountIn, currentPrice);
            euint64 actualOut = FHE.select(canExecute, outAmountAssumed, FHE.asEuint64(0));

            balancesOut[users[i]] = FHE.add(balancesOut[users[i]], actualOut);
            FHE.allowThis(balancesOut[users[i]]);

            // Mark as filled if executed
            userOrder.isFilled = FHE.select(canExecute, FHE.asEbool(true), userOrder.isFilled);
            FHE.allowThis(userOrder.isFilled);
        }
    }
}
