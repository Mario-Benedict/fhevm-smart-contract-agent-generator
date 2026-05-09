// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract OTCDarkpool_b5_006 is ZamaEthereumConfig {
    struct Order {
        euint64 minPrice;
        euint64 amountToSell;
        ebool isFilled;
    }

    Order private currentAsk;
    address public seller;

    constructor() {
        // Initialize an empty, filled order state
        currentAsk.isFilled = FHE.asEbool(true);
        FHE.allowThis(currentAsk.isFilled);
    }

    function placeAsk(
        externalEuint64 minPriceStr, 
        externalEuint64 amountStr, 
        bytes calldata proofPrice, 
        bytes calldata proofAmnt
    ) public {
        euint64 price = FHE.fromExternal(minPriceStr, proofPrice);
        euint64 amount = FHE.fromExternal(amountStr, proofAmnt);
        
        currentAsk = Order({
            minPrice: price,
            amountToSell: amount,
            isFilled: FHE.asEbool(false)
        });
        seller = msg.sender;
        
        FHE.allowThis(currentAsk.minPrice);
        FHE.allowThis(currentAsk.amountToSell);
        FHE.allowThis(currentAsk.isFilled);
    }

    function fillBid(
        externalEuint64 bidPriceStr, 
        externalEuint64 buyAmountStr, 
        bytes calldata proofPrice, 
        bytes calldata proofAmnt
    ) public {
        euint64 bidPrice = FHE.fromExternal(bidPriceStr, proofPrice);
        euint64 buyAmount = FHE.fromExternal(buyAmountStr, proofAmnt);
        
        // Execute IF bidPrice >= minPrice AND buyAmount >= amountToSell AND NOT isFilled
        ebool priceMatch = FHE.ge(bidPrice, currentAsk.minPrice);
        ebool amountMatch = FHE.ge(buyAmount, currentAsk.amountToSell);
        ebool available = FHE.not(currentAsk.isFilled);
        
        ebool executes = FHE.and(FHE.and(priceMatch, amountMatch), available);
        
        currentAsk.isFilled = FHE.select(executes, FHE.asEbool(true), currentAsk.isFilled);
        FHE.allowThis(currentAsk.isFilled);
        
        // Normally we'd credit msg.sender with the encrypted tokens and credit `seller` with payment
    }
}
