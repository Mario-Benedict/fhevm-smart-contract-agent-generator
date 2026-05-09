// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title WineryBarrelAuction - Fine wine barrel futures auction with encrypted bids and aging discounts
contract WineryBarrelAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Barrel {
        string vintage; string grape; uint256 liters; uint256 expectedReadyYear;
        address winery; euint64 reservePrice; euint64 highestBid; address highestBidder;
        uint256 auctionEnd; bool sold;
    }
    mapping(uint256 => Barrel) private barrels;
    mapping(uint256 => mapping(address => euint64)) private _bids;
    uint256 public barrelCount;
    mapping(address => euint64) private _wineryEarnings;

    event BarrelListed(uint256 indexed id, string vintage); event BidPlaced(uint256 indexed id, address bidder);
    event BarrelSold(uint256 indexed id, address buyer);

    constructor() Ownable(msg.sender) {}

    function listBarrel(string calldata vintage, string calldata grape, uint256 liters, uint256 readyYear,
        externalEuint64 encReserve, bytes calldata proof, uint256 days_) external returns (uint256 id) {
        euint64 reserve = FHE.fromExternal(encReserve, proof);
        id = barrelCount++;
        barrels[id].vintage = vintage;
        barrels[id].grape = grape;
        barrels[id].liters = liters;
        barrels[id].expectedReadyYear = readyYear;
        barrels[id].winery = msg.sender;
        barrels[id].reservePrice = reserve;
        barrels[id].highestBid = FHE.asEuint64(0);
        barrels[id].highestBidder = address(0);
        barrels[id].auctionEnd = block.timestamp + days_ * 1 days;
        barrels[id].sold = false;
        FHE.allowThis(barrels[id].reservePrice);
        FHE.allowThis(barrels[id].highestBid);
        emit BarrelListed(id, vintage);
    }

    function bid(uint256 barrelId, externalEuint64 encBid, bytes calldata proof) external nonReentrant {
        Barrel storage b = barrels[barrelId];
        require(!b.sold && block.timestamp < b.auctionEnd, "Over");
        euint64 bidAmt = FHE.fromExternal(encBid, proof);
        _bids[barrelId][msg.sender] = bidAmt;
        ebool isHigher = FHE.gt(bidAmt, b.highestBid);
        b.highestBid = FHE.select(isHigher, bidAmt, b.highestBid);
        if (FHE.isInitialized(isHigher)) b.highestBidder = msg.sender;
        FHE.allowThis(_bids[barrelId][msg.sender]);
        FHE.allowThis(b.highestBid);
        emit BidPlaced(barrelId, msg.sender);
    }

    function finalize(uint256 barrelId) external nonReentrant {
        Barrel storage b = barrels[barrelId];
        require(block.timestamp >= b.auctionEnd && !b.sold, "Not ready");
        b.sold = true;
        ebool meetsReserve = FHE.ge(b.highestBid, b.reservePrice);
        if (FHE.isInitialized(meetsReserve) && b.highestBidder != address(0)) {
            _wineryEarnings[b.winery] = FHE.add(_wineryEarnings[b.winery], b.highestBid);
            FHE.allowThis(_wineryEarnings[b.winery]);
            FHE.allow(_wineryEarnings[b.winery], b.winery);
            FHE.allow(b.highestBid, b.highestBidder);
            emit BarrelSold(barrelId, b.highestBidder);
        }
    }

    function withdrawEarnings() external nonReentrant {
        euint64 e = _wineryEarnings[msg.sender];
        _wineryEarnings[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_wineryEarnings[msg.sender]);
        FHE.allow(e, msg.sender);
    }

    function allowBarrelDetails(uint256 id, address viewer) external {
        require(barrels[id].winery == msg.sender || msg.sender == owner(), "Unauthorized");
        FHE.allow(barrels[id].reservePrice, viewer);
        FHE.allow(barrels[id].highestBid, viewer);
    }
}
