// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ReverseAuctionProcurement_b6_002 is ZamaEthereumConfig {
    address public procurementOfficer;
    
    euint64 private lowestBid;
    address public winningBidder; // Known winner after reveal, but we will keep bids hidden during process
    mapping(address => euint64) private bids;

    bool public isAuctionOpen;

    constructor() {
        procurementOfficer = msg.sender;
        // Init with highest possible 64-bit value to allow minimums
        lowestBid = FHE.asEuint64(18446744073709551615); 
        FHE.allowThis(lowestBid);
        isAuctionOpen = true;
    }

    function submitBid(externalEuint64 bidAmountStr, bytes calldata proof) public {
        require(isAuctionOpen, "Auction closed");
        euint64 amount = FHE.fromExternal(bidAmountStr, proof);
        bids[msg.sender] = amount;
        FHE.allowThis(bids[msg.sender]);

        // Evaluate if this is the new lowest bid
        ebool isLower = FHE.lt(amount, lowestBid);
        lowestBid = FHE.select(isLower, amount, lowestBid);
        FHE.allowThis(lowestBid);

        // Note: For fully blind evaluation without leaking the winner real-time, 
        // we wouldn't update plaintext `winningBidder` conditionally. We just keep lowestBid hidden.
    }

    function closeAuction() public {
        require(msg.sender == procurementOfficer, "Not authorized");
        isAuctionOpen = false;
    }
}
