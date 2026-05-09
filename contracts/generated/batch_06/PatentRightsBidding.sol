// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PatentRightsBidding
/// @notice Patent holders list IP rights for sealed auction.
///         Bidders compete privately; winner gets encrypted license terms.
contract PatentRightsBidding is ZamaEthereumConfig, Ownable {
    struct Patent {
        address holder;
        string title;
        string ipfsMetadataHash;
        euint64 reservePrice;
        euint64 highestBid;
        address highestBidder;
        uint256 deadline;
        bool auctioned;
        bool exclusive; // exclusive vs non-exclusive license
    }

    mapping(uint256 => Patent) private patents;
    mapping(address => mapping(uint256 => euint64)) private _bids;
    mapping(uint256 => mapping(address => bool)) public hasBid;
    uint256 public patentCount;
    euint64 private _totalRevenue;

    event PatentListed(uint256 indexed id, address holder);
    event BidPlaced(uint256 indexed id, address bidder);
    event PatentSold(uint256 indexed id, address buyer);

    constructor() Ownable(msg.sender) {
        _totalRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalRevenue);
    }

    function listPatent(
        string calldata title,
        string calldata metadataHash,
        bool exclusive,
        externalEuint64 encReserve, bytes calldata proof,
        uint256 durationDays
    ) external returns (uint256 id) {
        euint64 reserve = FHE.fromExternal(encReserve, proof);
        id = patentCount++;
        patents[id].holder = msg.sender;
        patents[id].title = title;
        patents[id].ipfsMetadataHash = metadataHash;
        patents[id].reservePrice = reserve;
        patents[id].highestBid = FHE.asEuint64(0);
        patents[id].highestBidder = address(0);
        patents[id].deadline = block.timestamp + durationDays * 1 days;
        patents[id].auctioned = false;
        patents[id].exclusive = exclusive;
        FHE.allowThis(patents[id].reservePrice);
        FHE.allowThis(patents[id].highestBid);
        emit PatentListed(id, msg.sender);
    }

    function bid(uint256 patentId, externalEuint64 encBid, bytes calldata proof) external {
        Patent storage p = patents[patentId];
        require(!p.auctioned && block.timestamp < p.deadline, "Auction over");
        require(!hasBid[patentId][msg.sender], "Already bid");
        hasBid[patentId][msg.sender] = true;
        euint64 bidAmt = FHE.fromExternal(encBid, proof);
        _bids[msg.sender][patentId] = bidAmt;
        ebool isHigher = FHE.gt(bidAmt, p.highestBid);
        p.highestBid = FHE.select(isHigher, bidAmt, p.highestBid);
        if (FHE.isInitialized(isHigher)) p.highestBidder = msg.sender;
        FHE.allowThis(_bids[msg.sender][patentId]);
        FHE.allowThis(p.highestBid);
        emit BidPlaced(patentId, msg.sender);
    }

    function finalize(uint256 patentId) external {
        Patent storage p = patents[patentId];
        require(msg.sender == p.holder || msg.sender == owner(), "Unauthorized");
        require(block.timestamp >= p.deadline && !p.auctioned, "Not ready");
        p.auctioned = true;
        ebool meetsReserve = FHE.ge(p.highestBid, p.reservePrice);
        if (FHE.isInitialized(meetsReserve) && p.highestBidder != address(0)) {
            _totalRevenue = FHE.add(_totalRevenue, p.highestBid);
            FHE.allow(p.highestBid, p.holder);
            FHE.allowThis(_totalRevenue);
            emit PatentSold(patentId, p.highestBidder);
        }
    }

    function allowPatentDetails(uint256 patentId, address viewer) external {
        Patent storage p = patents[patentId];
        require(msg.sender == p.holder || msg.sender == owner(), "Unauthorized");
        FHE.allow(p.reservePrice, viewer);
        FHE.allow(p.highestBid, viewer);
    }
}
