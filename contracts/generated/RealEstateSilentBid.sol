// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RealEstateSilentBid - Encrypted sealed-bid auction for real estate property listings
contract RealEstateSilentBid is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Property {
        string propertyId;
        address seller;
        euint64 reservePrice;
        euint64 highestBid;
        address highestBidder;
        uint256 auctionEnd;
        bool settled;
        bool active;
    }

    mapping(uint256 => Property) public properties;
    mapping(uint256 => mapping(address => euint64)) private bids;
    uint256 public propertyCount;

    event PropertyListed(uint256 indexed propId, address indexed seller);
    event BidPlaced(uint256 indexed propId, address indexed bidder);
    event AuctionSettled(uint256 indexed propId, address indexed winner);

    constructor() Ownable(msg.sender) {}

    function listProperty(
        string calldata propertyId,
        uint256 duration,
        externalEuint64 calldata encReserve,
        bytes calldata inputProof
    ) external returns (uint256 propId) {
        propId = propertyCount++;
        Property storage p = properties[propId];
        p.propertyId = propertyId;
        p.seller = msg.sender;
        p.reservePrice = FHE.fromExternal(encReserve, inputProof);
        p.highestBid = FHE.asEuint64(0);
        p.auctionEnd = block.timestamp + duration;
        p.active = true;
        FHE.allowThis(p.reservePrice);
        FHE.allowThis(p.highestBid);
        FHE.allow(p.reservePrice, msg.sender);
        emit PropertyListed(propId, msg.sender);
    }

    function placeBid(uint256 propId, externalEuint64 calldata encBid, bytes calldata inputProof) external {
        Property storage p = properties[propId];
        require(p.active && block.timestamp <= p.auctionEnd, "Auction not active");

        euint64 bid = FHE.fromExternal(encBid, inputProof);
        bids[propId][msg.sender] = bid;
        FHE.allowThis(bids[propId][msg.sender]);

        ebool isHigher = FHE.gt(bid, p.highestBid);
        p.highestBid = FHE.select(isHigher, bid, p.highestBid);
        FHE.allowThis(p.highestBid);

        if (FHE.gt(bid, p.highestBid).unwrap() != 0) {
            p.highestBidder = msg.sender;
        }
        emit BidPlaced(propId, msg.sender);
    }

    function settleAuction(uint256 propId) external nonReentrant {
        Property storage p = properties[propId];
        require(block.timestamp > p.auctionEnd, "Not ended");
        require(!p.settled, "Already settled");
        require(msg.sender == p.seller || msg.sender == owner(), "Unauthorized");
        p.settled = true;
        p.active = false;
        FHE.allow(p.highestBid, p.seller);
        FHE.allow(p.highestBid, p.highestBidder);
        emit AuctionSettled(propId, p.highestBidder);
    }

    function getMyBid(uint256 propId) external view returns (euint64) {
        return bids[propId][msg.sender];
    }
}
