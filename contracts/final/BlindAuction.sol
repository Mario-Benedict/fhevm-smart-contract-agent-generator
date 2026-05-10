// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract BlindAuction is ZamaEthereumConfig {
    address public highestBidder;
    euint64 private highestBid;
    mapping(address => euint64) private bids;

    constructor() {
        highestBid = FHE.asEuint64(0);
        FHE.allowThis(highestBid);
    }

    function bid(externalEuint64 bidAmount, bytes calldata inputProof) public {
        euint64 amount = FHE.fromExternal(bidAmount, inputProof);
        bids[msg.sender] = amount;
        FHE.allowThis(bids[msg.sender]);

        ebool isHigher = FHE.gt(amount, highestBid);
        highestBid = FHE.select(isHigher, amount, highestBid);
        FHE.allowThis(highestBid);
    }
}
