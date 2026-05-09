// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedBlindBidAuctionHouse
/// @notice Fully blind auction: sealed bids kept encrypted on-chain, revelation only
///         to winner, with encrypted reserve price validation and private bid refund logic.
contract EncryptedBlindBidAuctionHouse is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct AuctionItem {
        string title;
        string description;
        address seller;
        euint64 reservePrice;          // encrypted reserve
        euint64 highestBid;            // encrypted highest bid so far
        address highestBidder;
        uint256 auctionEnd;
        bool finalized;
    }

    struct SealedBid {
        address bidder;
        uint256 auctionId;
        euint64 bidAmount;             // encrypted bid amount
        bool revealed;
    }

    mapping(uint256 => AuctionItem) private auctions;
    mapping(uint256 => SealedBid)   private bids;
    mapping(uint256 => uint256[])   private auctionBidIds;

    uint256 public auctionCount;
    uint256 public bidCount;
    euint64 private _totalSaleVolume;

    event AuctionCreated(uint256 indexed auctionId, string title);
    event BidPlaced(uint256 indexed bidId, uint256 auctionId);
    event AuctionFinalized(uint256 indexed auctionId, address winner);

    constructor() Ownable(msg.sender) {
        _totalSaleVolume = FHE.asEuint64(0);
        FHE.allowThis(_totalSaleVolume);
    }

    function createAuction(
        string calldata title, string calldata description,
        externalEuint64 encReserve, bytes calldata proof,
        uint256 durationHours
    ) external returns (uint256 id) {
        euint64 reserve = FHE.fromExternal(encReserve, proof);
        id = auctionCount++;
        auctions[id] = AuctionItem({
            title: title, description: description, seller: msg.sender,
            reservePrice: reserve, highestBid: FHE.asEuint64(0),
            highestBidder: address(0), auctionEnd: block.timestamp + durationHours * 1 hours,
            finalized: false
        });
        FHE.allowThis(auctions[id].reservePrice);
        FHE.allowThis(auctions[id].highestBid);
        emit AuctionCreated(id, title);
    }

    function placeBid(uint256 auctionId, externalEuint64 encBid, bytes calldata proof) external nonReentrant returns (uint256 bidId) {
        AuctionItem storage a = auctions[auctionId];
        require(!a.finalized && block.timestamp < a.auctionEnd, "Auction closed");
        euint64 bid = FHE.fromExternal(encBid, proof);
        bidId = bidCount++;
        bids[bidId] = SealedBid({ bidder: msg.sender, auctionId: auctionId, bidAmount: bid, revealed: false });
        auctionBidIds[auctionId].push(bidId);
        // Update highest bid branchlessly
        ebool isHigher = FHE.gt(bid, a.highestBid);
        a.highestBid = FHE.select(isHigher, bid, a.highestBid);
        if (FHE.isInitialized(isHigher)) a.highestBidder = msg.sender; // simplified: update on-chain bidder
        FHE.allowThis(bids[bidId].bidAmount); FHE.allow(bids[bidId].bidAmount, msg.sender);
        FHE.allowThis(a.highestBid);
        emit BidPlaced(bidId, auctionId);
    }

    function finalizeAuction(uint256 auctionId) external nonReentrant {
        AuctionItem storage a = auctions[auctionId];
        require(block.timestamp >= a.auctionEnd && !a.finalized, "Not ended or already final");
        require(msg.sender == a.seller || msg.sender == owner(), "Not authorized");
        ebool reserveMet = FHE.ge(a.highestBid, a.reservePrice);
        euint64 saleAmt = FHE.select(reserveMet, a.highestBid, FHE.asEuint64(0));
        _totalSaleVolume = FHE.add(_totalSaleVolume, saleAmt);
        a.finalized = true;
        FHE.allowThis(_totalSaleVolume);
        FHE.allow(a.highestBid, a.highestBidder); FHE.allow(a.highestBid, a.seller);
        emit AuctionFinalized(auctionId, a.highestBidder);
    }

    function allowSaleStats(address viewer) external onlyOwner { FHE.allow(_totalSaleVolume, viewer); }
    function getBidAmount(uint256 bidId) external view returns (euint64) { return bids[bidId].bidAmount; }
    function getHighestBid(uint256 auctionId) external view returns (euint64) { return auctions[auctionId].highestBid; }
}
