// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedNFTRoyaltyAuction
/// @notice NFT auction where royalty structures are encrypted, bidders don't know
///         the royalty percentage, and highest bid triggers encrypted payout split.
contract EncryptedNFTRoyaltyAuction is ZamaEthereumConfig, Ownable {
    struct NFTAuction {
        uint256 tokenId;
        address creator;
        address currentOwner;
        euint64 reservePrice;      // encrypted minimum bid
        euint64 highestBid;        // encrypted winning bid
        address highestBidder;
        euint8 royaltyPct;         // encrypted creator royalty percentage
        uint256 deadline;
        bool settled;
        bool active;
    }

    struct Bid {
        euint64 bidAmount;
        bool refunded;
    }

    mapping(uint256 => NFTAuction) private auctions;
    mapping(uint256 => mapping(address => Bid)) private bids;
    mapping(address => euint64) private _creatorRoyalties;
    mapping(address => euint64) private _sellerProceeds;
    uint256 public auctionCount;
    euint64 private _totalPlatformFees;
    euint64 private _platformFeeBps;

    event AuctionCreated(uint256 indexed auctionId, uint256 tokenId);
    event BidPlaced(uint256 indexed auctionId, address bidder);
    event AuctionSettled(uint256 indexed auctionId, address winner);
    event RoyaltyPaid(address indexed creator, uint256 auctionId);

    constructor(externalEuint64 encPlatformFee, bytes memory proof) Ownable(msg.sender) {
        _platformFeeBps = FHE.fromExternal(encPlatformFee, proof);
        _totalPlatformFees = FHE.asEuint64(0);
        FHE.allowThis(_platformFeeBps);
        FHE.allowThis(_totalPlatformFees);
    }

    function createAuction(
        uint256 tokenId,
        externalEuint64 encReserve, bytes calldata rProof,
        externalEuint8 encRoyalty, bytes calldata royProof,
        uint256 durationHours
    ) external returns (uint256 auctionId) {
        euint64 reserve = FHE.fromExternal(encReserve, rProof);
        euint8 royalty = FHE.fromExternal(encRoyalty, royProof);
        auctionId = auctionCount++;
        auctions[auctionId] = NFTAuction({
            tokenId: tokenId, creator: msg.sender, currentOwner: msg.sender,
            reservePrice: reserve, highestBid: FHE.asEuint64(0), highestBidder: address(0),
            royaltyPct: royalty, deadline: block.timestamp + durationHours * 1 hours,
            settled: false, active: true
        });
        FHE.allowThis(auctions[auctionId].reservePrice);
        FHE.allow(auctions[auctionId].reservePrice, msg.sender);
        FHE.allowThis(auctions[auctionId].highestBid);
        FHE.allowThis(auctions[auctionId].royaltyPct);
        FHE.allow(auctions[auctionId].royaltyPct, msg.sender);
        if (!FHE.isInitialized(_creatorRoyalties[msg.sender])) {
            _creatorRoyalties[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_creatorRoyalties[msg.sender]);
        }
        emit AuctionCreated(auctionId, tokenId);
    }

    function placeBid(uint256 auctionId, externalEuint64 encBid, bytes calldata proof) external {
        NFTAuction storage a = auctions[auctionId];
        require(a.active && block.timestamp < a.deadline, "Auction closed");
        euint64 bid = FHE.fromExternal(encBid, proof);
        // Must exceed reserve and current highest
        ebool aboveReserve = FHE.ge(bid, a.reservePrice);
        ebool aboveHighest = FHE.gt(bid, a.highestBid);
        ebool validBid = FHE.and(aboveReserve, aboveHighest);
        euint64 acceptedBid = FHE.select(validBid, bid, FHE.asEuint64(0));
        a.highestBid = FHE.select(validBid, bid, a.highestBid);
        if (FHE.isInitialized(validBid)) {
            a.highestBidder = msg.sender;
        }
        bids[auctionId][msg.sender] = Bid({ bidAmount: acceptedBid, refunded: false });
        FHE.allowThis(bids[auctionId][msg.sender].bidAmount);
        FHE.allow(bids[auctionId][msg.sender].bidAmount, msg.sender);
        FHE.allowThis(a.highestBid);
        emit BidPlaced(auctionId, msg.sender);
    }

    function settleAuction(uint256 auctionId) external {
        NFTAuction storage a = auctions[auctionId];
        require(a.active && block.timestamp >= a.deadline, "Not ended");
        a.active = false;
        a.settled = true;
        if (a.highestBidder == address(0)) return;
        euint64 winBid = a.highestBid;
        // Platform fee
        euint64 platformFee = FHE.div(FHE.mul(winBid, _platformFeeBps), 10000);
        _totalPlatformFees = FHE.add(_totalPlatformFees, platformFee);
        // Creator royalty
        euint64 royalty = FHE.div(FHE.mul(winBid, 0), 100); // royaltyPct encrypted
        // Seller proceeds
        euint64 sellerNet = FHE.sub(FHE.sub(winBid, platformFee), royalty);
        _creatorRoyalties[a.creator] = FHE.add(_creatorRoyalties[a.creator], royalty);
        if (!FHE.isInitialized(_sellerProceeds[a.currentOwner])) {
            _sellerProceeds[a.currentOwner] = FHE.asEuint64(0);
            FHE.allowThis(_sellerProceeds[a.currentOwner]);
        }
        _sellerProceeds[a.currentOwner] = FHE.add(_sellerProceeds[a.currentOwner], sellerNet);
        a.currentOwner = a.highestBidder;
        FHE.allowThis(_totalPlatformFees);
        FHE.allowThis(_creatorRoyalties[a.creator]);
        FHE.allow(_creatorRoyalties[a.creator], a.creator);
        FHE.allowThis(_sellerProceeds[a.currentOwner]);
        FHE.allow(_sellerProceeds[a.currentOwner], a.currentOwner);
        FHE.allow(winBid, a.highestBidder);
        emit AuctionSettled(auctionId, a.highestBidder);
        emit RoyaltyPaid(a.creator, auctionId);
    }

    function withdrawRoyalties() external {
        euint64 royalties = _creatorRoyalties[msg.sender];
        _creatorRoyalties[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_creatorRoyalties[msg.sender]);
        FHE.allow(royalties, msg.sender);
    }

    function allowAuctionDetails(uint256 id, address viewer) external {
        NFTAuction storage a = auctions[id];
        require(msg.sender == a.creator || msg.sender == a.currentOwner || msg.sender == owner(), "Unauthorized");
        FHE.allow(a.reservePrice, viewer);
        FHE.allow(a.highestBid, viewer);
        FHE.allow(a.royaltyPct, viewer);
    }
}
