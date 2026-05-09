// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SportingEventTicketAuction - VIP event tickets auctioned with dynamic encrypted pricing
contract SportingEventTicketAuction is ZamaEthereumConfig, Ownable {
    struct TicketLot {
        string event_; uint256 seatCount; string section;
        euint64 floorPrice; euint64 highestBid; address highestBidder;
        uint256 deadline; bool sold;
    }
    mapping(uint256 => TicketLot) private lots;
    mapping(uint256 => mapping(address => euint64)) private _bids;
    mapping(address => bool) public isVerifiedFan;
    uint256 public lotCount;

    event LotCreated(uint256 indexed id, string event_); event BidPlaced(uint256 indexed id, address fan);
    event LotSold(uint256 indexed id, address buyer);

    constructor() Ownable(msg.sender) {}
    function verifyFan(address f) external onlyOwner { isVerifiedFan[f] = true; }

    function createLot(string calldata event_, uint256 seats, string calldata section,
        externalEuint64 encFloor, bytes calldata proof, uint256 days_) external onlyOwner returns (uint256 id) {
        euint64 floor = FHE.fromExternal(encFloor, proof);
        id = lotCount++;
        lots[id] = TicketLot({ event_: event_, seatCount: seats, section: section, floorPrice: floor,
            highestBid: FHE.asEuint64(0), highestBidder: address(0),
            deadline: block.timestamp + days_ * 1 days, sold: false });
        FHE.allowThis(lots[id].floorPrice);
        FHE.allowThis(lots[id].highestBid);
        emit LotCreated(id, event_);
    }

    function bid(uint256 lotId, externalEuint64 encBid, bytes calldata proof) external {
        require(isVerifiedFan[msg.sender] && !lots[lotId].sold && block.timestamp < lots[lotId].deadline, "Invalid");
        euint64 bidAmt = FHE.fromExternal(encBid, proof);
        _bids[lotId][msg.sender] = bidAmt;
        ebool isHigher = FHE.gt(bidAmt, lots[lotId].highestBid);
        lots[lotId].highestBid = FHE.select(isHigher, bidAmt, lots[lotId].highestBid);
        if (FHE.isInitialized(isHigher)) lots[lotId].highestBidder = msg.sender;
        FHE.allowThis(_bids[lotId][msg.sender]);
        FHE.allowThis(lots[lotId].highestBid);
        emit BidPlaced(lotId, msg.sender);
    }

    function finalize(uint256 lotId) external onlyOwner {
        TicketLot storage lot = lots[lotId];
        require(block.timestamp >= lot.deadline && !lot.sold, "Not ready");
        lot.sold = true;
        ebool ok = FHE.ge(lot.highestBid, lot.floorPrice);
        if (FHE.isInitialized(ok) && lot.highestBidder != address(0)) {
            FHE.allow(lot.highestBid, lot.highestBidder);
            emit LotSold(lotId, lot.highestBidder);
        }
    }

    function allowLotDetails(uint256 id, address viewer) external onlyOwner {
        FHE.allow(lots[id].floorPrice, viewer);
        FHE.allow(lots[id].highestBid, viewer);
    }
}
