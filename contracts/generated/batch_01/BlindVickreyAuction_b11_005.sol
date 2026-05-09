// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract BlindVickreyAuction_b11_005 is ZamaEthereumConfig {
    address public seller;
    euint64 private highestBid;
    euint64 private secondHighestBid;

    constructor() {
        seller = msg.sender;
        highestBid = FHE.asEuint64(0);
        secondHighestBid = FHE.asEuint64(0);
        FHE.allowThis(highestBid);
        FHE.allowThis(secondHighestBid);
    }

    function bid(externalEuint64 bidStr, bytes calldata proof) public {
        euint64 newBid = FHE.fromExternal(bidStr, proof);
        ebool isHighest = FHE.gt(newBid, highestBid);
        
        secondHighestBid = FHE.select(isHighest, highestBid, secondHighestBid);
        highestBid = FHE.select(isHighest, newBid, highestBid);
        
        FHE.allowThis(highestBid);
        FHE.allowThis(secondHighestBid);
    }
}
