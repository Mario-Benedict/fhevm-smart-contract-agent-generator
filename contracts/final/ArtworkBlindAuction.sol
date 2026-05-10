// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title ArtworkBlindAuction - NFT artwork auction with encrypted bids
contract ArtworkBlindAuction is ZamaEthereumConfig, Ownable {
    struct ArtAuction {
        address nftContract;
        uint256 tokenId;
        address artist;
        euint64 highestBid;
        eaddress encHighestBidder;
        address revealedWinner;
        uint256 endTime;
        bool finalized;
        uint16 royaltyBps;
    }

    mapping(uint256 => ArtAuction) public auctions;
    mapping(uint256 => mapping(address => euint64)) private bidAmounts;
    uint256 public auctionCount;

    event AuctionStarted(uint256 indexed auctionId, address indexed nftContract, uint256 tokenId);
    event BidSubmitted(uint256 indexed auctionId, address indexed bidder);
    event AuctionFinalized(uint256 indexed auctionId, address indexed winner);

    constructor() Ownable(msg.sender) {}

    function startAuction(
        address nftContract,
        uint256 tokenId,
        uint256 duration,
        uint16 royaltyBps
    ) external returns (uint256 auctionId) {
        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);
        auctionId = auctionCount++;
        ArtAuction storage a = auctions[auctionId];
        a.nftContract = nftContract;
        a.tokenId = tokenId;
        a.artist = msg.sender;
        a.highestBid = FHE.asEuint64(0);
        a.encHighestBidder = FHE.asEaddress(address(0));
        a.endTime = block.timestamp + duration;
        a.royaltyBps = royaltyBps;
        FHE.allowThis(a.highestBid);
        FHE.allowThis(a.encHighestBidder);
        emit AuctionStarted(auctionId, nftContract, tokenId);
    }

    function submitBid(uint256 auctionId, externalEuint64 encBid, bytes calldata inputProof) external {
        ArtAuction storage a = auctions[auctionId];
        require(block.timestamp <= a.endTime, "Ended");
        require(!a.finalized, "Finalized");

        euint64 bid = FHE.fromExternal(encBid, inputProof);
        bidAmounts[auctionId][msg.sender] = bid;
        FHE.allowThis(bidAmounts[auctionId][msg.sender]);

        ebool higher = FHE.gt(bid, a.highestBid);
        a.highestBid = FHE.select(higher, bid, a.highestBid);
        a.encHighestBidder = FHE.select(higher, FHE.asEaddress(msg.sender), a.encHighestBidder);
        FHE.allowThis(a.highestBid);
        FHE.allowThis(a.encHighestBidder);
        emit BidSubmitted(auctionId, msg.sender);
    }

    function finalizeAuction(uint256 auctionId, address winner) external onlyOwner {
        ArtAuction storage a = auctions[auctionId];
        require(block.timestamp > a.endTime, "Not ended");
        require(!a.finalized, "Done");
        a.finalized = true;
        a.revealedWinner = winner;
        IERC721(a.nftContract).transferFrom(address(this), winner, a.tokenId);
        FHE.allow(a.highestBid, a.artist);
        FHE.allow(a.highestBid, winner);
        FHE.allow(a.encHighestBidder, owner());
        emit AuctionFinalized(auctionId, winner);
    }
}
