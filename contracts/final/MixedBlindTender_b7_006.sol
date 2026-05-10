// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title MixedBlindTender_b7_006 - Blind procurement tender with private bids
contract MixedBlindTender_b7_006 is ZamaEthereumConfig {
    address public procurer;
    string public tenderDescription;
    uint256 public submissionDeadline;
    bool public awarded;
    address public winner;

    struct TenderBid {
        euint64 price;
        euint32 deliveryDays;
        bool submitted;
    }

    mapping(address => TenderBid) private bids;
    address[] public bidders;
    euint64 private lowestBid;
    address private lowestBidder;

    modifier onlyProcurer() {
        require(msg.sender == procurer, "Not procurer");
        _;
    }

    constructor(string memory description, uint256 durationDays) {
        procurer = msg.sender;
        tenderDescription = description;
        submissionDeadline = block.timestamp + durationDays * 1 days;
        lowestBid = FHE.asEuint64(type(uint64).max);
        FHE.allowThis(lowestBid);
    }

    function submitBid(
        externalEuint64 priceStr, bytes calldata priceProof,
        externalEuint32 daysStr, bytes calldata daysProof
    ) public {
        require(block.timestamp < submissionDeadline, "Deadline passed");
        require(!bids[msg.sender].submitted, "Already submitted");
        euint64 price = FHE.fromExternal(priceStr, priceProof);
        euint64 priceWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 priceExposure = FHE.sub(priceWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint32 days_ = FHE.fromExternal(daysStr, daysProof);
        bids[msg.sender] = TenderBid({ price: price, deliveryDays: days_, submitted: true });
        FHE.allowThis(bids[msg.sender].price);
        FHE.allowThis(bids[msg.sender].deliveryDays);
        bidders.push(msg.sender);

        ebool isLower = FHE.lt(price, lowestBid);
        lowestBid = FHE.select(isLower, price, lowestBid);
        if (FHE.isInitialized(isLower)) lowestBidder = msg.sender;
        FHE.allowThis(lowestBid);
    }

    function awardTender() public onlyProcurer {
        require(block.timestamp >= submissionDeadline, "Deadline not reached");
        require(!awarded, "Already awarded");
        awarded = true;
        winner = lowestBidder;
        FHE.allow(lowestBid, winner);
        FHE.allow(bids[winner].deliveryDays, winner);
    }

    function allowBid(address bidder, address viewer) public onlyProcurer {
        FHE.allow(bids[bidder].price, viewer);
        FHE.allow(bids[bidder].deliveryDays, viewer);
    }

    function getBidderCount() public view returns (uint256) {
        return bidders.length;
    }
}
