// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract BlindAuctionMulti_b3_005 is ZamaEthereumConfig {
    euint64 private highestBid;
    euint64 private secondHighestBid;

    constructor() {
        highestBid = FHE.asEuint64(0);
        secondHighestBid = FHE.asEuint64(0);
        FHE.allowThis(highestBid);
        FHE.allowThis(secondHighestBid);
    }

    function bid(externalEuint64 bidAmount, bytes calldata inputProof) public {
        euint64 amount = FHE.fromExternal(bidAmount, inputProof);
        
        ebool isHighest = FHE.gt(amount, highestBid);
        ebool isSecond = FHE.and(FHE.not(isHighest), FHE.gt(amount, secondHighestBid));

        // Logic trick: replace second highest if it's the new highest, or if it just beats the second highest
        secondHighestBid = FHE.select(isHighest, highestBid, FHE.select(isSecond, amount, secondHighestBid));
        highestBid = FHE.select(isHighest, amount, highestBid);

        FHE.allowThis(highestBid);
        FHE.allowThis(secondHighestBid);
    }
}
