// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BlindDutchAuction_b13_004 is ZamaEthereumConfig, Ownable {
    euint64 public currentPrice;
    euint64 public reservePrice;
    ebool public isSold;

    constructor() Ownable(msg.sender) {
        currentPrice = FHE.asEuint64(1000);
        reservePrice = FHE.asEuint64(500);
        isSold = FHE.asEbool(false);
        FHE.allowThis(currentPrice);
        FHE.allowThis(reservePrice);
        FHE.allowThis(isSold);
    }

    function dropPrice(externalEuint64 dropStr, bytes calldata proof) public onlyOwner {
        euint64 drop = FHE.fromExternal(dropStr, proof);
        currentPrice = FHE.sub(currentPrice, drop);
        
        // Ensure price doesn't go below reserve
        ebool belowReserve = FHE.lt(currentPrice, reservePrice);
        currentPrice = FHE.select(belowReserve, reservePrice, currentPrice);
        
        FHE.allowThis(currentPrice);
    }

    function blindBid(externalEuint64 bidStr, bytes calldata proof) public {
        euint64 bidAmount = FHE.fromExternal(bidStr, proof);
        
        ebool notSold = FHE.not(isSold);
        ebool meetsPrice = FHE.ge(bidAmount, currentPrice);
        
        ebool successfulBid = FHE.and(notSold, meetsPrice);
        isSold = FHE.select(successfulBid, FHE.asEbool(true), isSold);
        
        FHE.allowThis(isSold);
    }
}
