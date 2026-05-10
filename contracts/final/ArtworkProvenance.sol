// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ArtworkProvenance
/// @notice Art gallery blind auction: artists list work with encrypted minimum,
///         collectors bid privately, gallery earns encrypted commission.
contract ArtworkProvenance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Artwork {
        address artist;
        string title;
        string medium;
        string ipfsImage;
        euint64 reservePrice;
        euint64 highestBid;
        address highestBidder;
        uint256 auctionEnd;
        bool sold;
        uint256 provenanceYear;
    }

    struct ProvenanceRecord {
        address prevOwner;
        address newOwner;
        uint256 transferDate;
        euint64 salePrice;
    }

    mapping(uint256 => Artwork) private artworks;
    mapping(uint256 => ProvenanceRecord[]) private provenance;
    mapping(uint256 => mapping(address => euint64)) private _bids;
    uint256 public artworkCount;
    uint16 public galleryCommissionBps;
    mapping(address => euint64) private _artistEarnings;
    euint64 private _galleryRevenue;

    event ArtworkListed(uint256 indexed id, address artist, string title);
    event BidPlaced(uint256 indexed id, address bidder);
    event ArtworkSold(uint256 indexed id, address buyer);

    constructor(uint16 commissionBps) Ownable(msg.sender) {
        galleryCommissionBps = commissionBps;
        _galleryRevenue = FHE.asEuint64(0);
        FHE.allowThis(_galleryRevenue);
    }

    function listArtwork(
        string calldata title,
        string calldata medium,
        string calldata ipfsImage,
        uint256 provenanceYear,
        externalEuint64 encReserve, bytes calldata proof,
        uint256 auctionDays
    ) external returns (uint256 id) {
        euint64 reserve = FHE.fromExternal(encReserve, proof);
        id = artworkCount++;
        artworks[id].artist = msg.sender;
        artworks[id].title = title;
        artworks[id].medium = medium;
        artworks[id].ipfsImage = ipfsImage;
        artworks[id].reservePrice = reserve;
        artworks[id].highestBid = FHE.asEuint64(0);
        artworks[id].highestBidder = address(0);
        artworks[id].auctionEnd = block.timestamp + auctionDays * 1 days;
        artworks[id].sold = false;
        artworks[id].provenanceYear = provenanceYear;
        FHE.allowThis(artworks[id].reservePrice);
        FHE.allow(artworks[id].reservePrice, msg.sender);
        FHE.allowThis(artworks[id].highestBid);
        emit ArtworkListed(id, msg.sender, title);
    }

    function placeBid(uint256 artworkId, externalEuint64 encBid, bytes calldata proof)
        external nonReentrant
    {
        Artwork storage art = artworks[artworkId];
        require(!art.sold && block.timestamp < art.auctionEnd, "Auction over");
        euint64 bid = FHE.fromExternal(encBid, proof);
        ebool isHigher = FHE.gt(bid, art.highestBid);
        art.highestBid = FHE.select(isHigher, bid, art.highestBid);
        if (FHE.isInitialized(isHigher)) art.highestBidder = msg.sender;
        _bids[artworkId][msg.sender] = bid;
        FHE.allowThis(_bids[artworkId][msg.sender]);
        FHE.allowThis(art.highestBid);
        emit BidPlaced(artworkId, msg.sender);
    }

    function finalizeAuction(uint256 artworkId) external nonReentrant {
        Artwork storage art = artworks[artworkId];
        require(block.timestamp >= art.auctionEnd && !art.sold, "Not ready");
        ebool meetsReserve = FHE.ge(art.highestBid, art.reservePrice);
        if (!FHE.isInitialized(meetsReserve) || art.highestBidder == address(0)) return;
        art.sold = true;
        euint64 commission = FHE.div(FHE.mul(art.highestBid, FHE.asEuint64(uint64(galleryCommissionBps))), 10000);
        ebool _safeSub3 = FHE.ge(art.highestBid, commission);
        euint64 artistCut = FHE.select(_safeSub3, FHE.sub(art.highestBid, commission), FHE.asEuint64(0));
        _artistEarnings[art.artist] = FHE.add(_artistEarnings[art.artist], artistCut);
        _galleryRevenue = FHE.add(_galleryRevenue, commission);
        provenance[artworkId].push(ProvenanceRecord({
            prevOwner: art.artist, newOwner: art.highestBidder,
            transferDate: block.timestamp, salePrice: art.highestBid
        }));
        FHE.allowThis(_artistEarnings[art.artist]);
        FHE.allow(_artistEarnings[art.artist], art.artist);
        FHE.allowThis(_galleryRevenue);
        FHE.allowThis(provenance[artworkId][provenance[artworkId].length - 1].salePrice);
        emit ArtworkSold(artworkId, art.highestBidder);
    }

    function withdrawArtistEarnings() external nonReentrant {
        euint64 earnings = _artistEarnings[msg.sender];
        _artistEarnings[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_artistEarnings[msg.sender]);
        FHE.allow(earnings, msg.sender);
    }

    function allowArtworkDetails(uint256 id, address viewer) external {
        Artwork storage art = artworks[id];
        require(msg.sender == art.artist || msg.sender == owner(), "Unauthorized");
        FHE.allow(art.reservePrice, viewer);
        FHE.allow(art.highestBid, viewer);
    }
}
