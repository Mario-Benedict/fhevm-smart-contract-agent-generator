// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title TimesharePropertyAuction - Resort timeshare weeks auctioned with encrypted bids and seasonal pricing
contract TimesharePropertyAuction is ZamaEthereumConfig, Ownable {
    struct TimeshareWeek {
        string resortName; uint8 weekNumber; uint8 unitType; // 1=studio,2=1BR,3=2BR
        address seller; euint64 askPrice; euint64 highestBid; address highestBidder;
        uint256 deadline; bool sold;
    }
    mapping(uint256 => TimeshareWeek) private listedWeeks;
    mapping(uint256 => mapping(address => euint64)) private _bids;
    uint256 public weekCount;

    event WeekListed(uint256 indexed id, string resort); event BidPlaced(uint256 indexed id, address buyer);
    event WeekSold(uint256 indexed id, address buyer);

    constructor() Ownable(msg.sender) {}

    function listWeek(string calldata resort, uint8 weekNum, uint8 unitType,
        externalEuint64 encAsk, bytes calldata proof, uint256 days_) external returns (uint256 id) {
        euint64 ask = FHE.fromExternal(encAsk, proof);
        id = weekCount++;
        listedWeeks[id] = TimeshareWeek({ resortName: resort, weekNumber: weekNum, unitType: unitType,
            seller: msg.sender, askPrice: ask, highestBid: FHE.asEuint64(0),
            highestBidder: address(0), deadline: block.timestamp + days_ * 1 days, sold: false });
        FHE.allowThis(listedWeeks[id].askPrice);
        FHE.allow(listedWeeks[id].askPrice, msg.sender);
        FHE.allowThis(listedWeeks[id].highestBid);
        emit WeekListed(id, resort);
    }

    function bid(uint256 weekId, externalEuint64 encBid, bytes calldata proof) external {
        TimeshareWeek storage w = listedWeeks[weekId];
        require(!w.sold && block.timestamp < w.deadline && msg.sender != w.seller, "Invalid");
        euint64 bidAmt = FHE.fromExternal(encBid, proof);
        _bids[weekId][msg.sender] = bidAmt;
        ebool isHigher = FHE.gt(bidAmt, w.highestBid);
        w.highestBid = FHE.select(isHigher, bidAmt, w.highestBid);
        if (FHE.isInitialized(isHigher)) w.highestBidder = msg.sender;
        FHE.allowThis(_bids[weekId][msg.sender]);
        FHE.allowThis(w.highestBid);
        emit BidPlaced(weekId, msg.sender);
    }

    function finalize(uint256 weekId) external {
        TimeshareWeek storage w = listedWeeks[weekId];
        require(block.timestamp >= w.deadline && !w.sold && msg.sender == w.seller, "Invalid");
        w.sold = true;
        ebool meetsAsk = FHE.ge(w.highestBid, w.askPrice);
        if (FHE.isInitialized(meetsAsk) && w.highestBidder != address(0)) {
            FHE.allow(w.highestBid, w.seller);
            FHE.allow(w.highestBid, w.highestBidder);
            emit WeekSold(weekId, w.highestBidder);
        }
    }

    function allowWeekDetails(uint256 id, address viewer) external {
        require(listedWeeks[id].seller == msg.sender || msg.sender == owner(), "Unauthorized");
        FHE.allow(listedWeeks[id].askPrice, viewer);
        FHE.allow(listedWeeks[id].highestBid, viewer);
    }
}
