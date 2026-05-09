// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateNFTBlindAuction
/// @notice NFT auction where all bids remain encrypted until finalization; prevents
///         bid sniping, front-running, and whale intimidation with FHE sealed bids.
contract PrivateNFTBlindAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct NFTAuction {
        address seller;
        address nftContract;
        uint256 tokenId;
        string metadataURI;
        euint64 reservePrice;          // encrypted floor
        euint64 highestBid;            // encrypted running max
        address highestBidder;
        uint256 startTime;
        uint256 endTime;
        bool settled;
    }

    struct EncryptedBid {
        address bidder;
        uint256 auctionId;
        euint64 amount;
        uint256 timestamp;
    }

    mapping(uint256 => NFTAuction) private auctions;
    mapping(uint256 => EncryptedBid) private bids;
    mapping(uint256 => uint256[]) private auctionBids;

    uint256 public auctionCount;
    uint256 public bidCount;
    euint64 private _totalGMV;

    event AuctionListed(uint256 indexed id, address nftContract, uint256 tokenId);
    event BidSubmitted(uint256 indexed bidId, uint256 auctionId);
    event AuctionSettled(uint256 indexed id, address winner);

    constructor() Ownable(msg.sender) {
        _totalGMV = FHE.asEuint64(0);
        FHE.allowThis(_totalGMV);
    }

    function listAuction(
        address nftContract, uint256 tokenId, string calldata metadataURI,
        externalEuint64 encReserve, bytes calldata proof,
        uint256 durationHours
    ) external returns (uint256 id) {
        euint64 reserve = FHE.fromExternal(encReserve, proof);
        id = auctionCount++;
        auctions[id].seller = msg.sender;
        auctions[id].nftContract = nftContract;
        auctions[id].tokenId = tokenId;
        auctions[id].metadataURI = metadataURI;
        auctions[id].reservePrice = reserve;
        auctions[id].highestBid = FHE.asEuint64(0);
        auctions[id].highestBidder = address(0);
        auctions[id].startTime = block.timestamp;
        auctions[id].endTime = block.timestamp + durationHours * 1 hours;
        auctions[id].settled = false;
        FHE.allowThis(auctions[id].reservePrice);
        FHE.allowThis(auctions[id].highestBid);
        emit AuctionListed(id, nftContract, tokenId);
    }

    function submitBid(uint256 auctionId, externalEuint64 encBid, bytes calldata proof) external nonReentrant returns (uint256 bidId) {
        NFTAuction storage a = auctions[auctionId];
        require(!a.settled && block.timestamp < a.endTime, "Auction ended");
        euint64 bid = FHE.fromExternal(encBid, proof);
        bidId = bidCount++;
        bids[bidId] = EncryptedBid({ bidder: msg.sender, auctionId: auctionId, amount: bid, timestamp: block.timestamp });
        auctionBids[auctionId].push(bidId);
        ebool isNew = FHE.gt(bid, a.highestBid);
        a.highestBid = FHE.select(isNew, bid, a.highestBid);
        if (FHE.isInitialized(isNew)) a.highestBidder = msg.sender;
        FHE.allowThis(bids[bidId].amount); FHE.allow(bids[bidId].amount, msg.sender);
        FHE.allowThis(a.highestBid);
        emit BidSubmitted(bidId, auctionId);
    }

    function settleAuction(uint256 auctionId) external nonReentrant {
        NFTAuction storage a = auctions[auctionId];
        require(block.timestamp >= a.endTime && !a.settled, "Cannot settle");
        require(msg.sender == a.seller || msg.sender == owner(), "Not authorized");
        ebool reserveMet = FHE.ge(a.highestBid, a.reservePrice);
        euint64 proceeds = FHE.select(reserveMet, a.highestBid, FHE.asEuint64(0));
        _totalGMV = FHE.add(_totalGMV, proceeds);
        a.settled = true;
        FHE.allow(a.highestBid, a.seller); FHE.allow(a.highestBid, a.highestBidder);
        FHE.allowThis(_totalGMV);
        emit AuctionSettled(auctionId, a.highestBidder);
    }

    function allowGMVView(address viewer) external onlyOwner { FHE.allow(_totalGMV, viewer); }
    function getBidAmount(uint256 bidId) external view returns (euint64) { return bids[bidId].amount; }
    function getHighestBid(uint256 auctionId) external view returns (euint64) { return auctions[auctionId].highestBid; }
}
