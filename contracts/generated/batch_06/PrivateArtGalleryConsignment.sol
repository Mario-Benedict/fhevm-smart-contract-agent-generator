// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateArtGalleryConsignment
/// @notice High-end art gallery consignment with encrypted reserve prices,
///         encrypted seller premiums, and encrypted hammer prices at auction.
contract PrivateArtGalleryConsignment is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ArtworkMedium { OilOnCanvas, Watercolor, Sculpture, Photography, DigitalArt, PrintMaking }
    enum SaleStatus { Consigned, AuctionPending, InAuction, Sold, Unsold, Withdrawn }

    struct Artwork {
        address consignor;
        string artistName;
        string title;
        uint256 yearCreated;
        ArtworkMedium medium;
        string dimensions;
        euint64 reservePriceUSD;        // encrypted reserve price
        euint64 estimateLowUSD;         // encrypted low estimate
        euint64 estimateHighUSD;        // encrypted high estimate
        euint64 hammerPriceUSD;         // encrypted winning bid
        euint32 premiumRateBps;         // encrypted buyer's premium rate
        euint64 sellerProceedsUSD;      // encrypted proceeds to consignor
        SaleStatus status;
        uint256 auctionDate;
    }

    struct Bid {
        uint256 artworkId;
        address bidder;
        euint64 bidAmountUSD;           // encrypted bid
        bool winning;
    }

    mapping(uint256 => Artwork) private artworks;
    mapping(uint256 => Bid[]) private bids;
    mapping(address => bool) public isConsignor;
    mapping(address => bool) public isAuctioneer;

    uint256 public artworkCount;
    uint256 public totalBidCount;
    euint64 private _totalHammerTotal;
    euint64 private _totalConsignorProceeds;

    event ArtworkConsigned(uint256 indexed id, string artist, string title);
    event BidPlaced(uint256 indexed artworkId, address bidder);
    event ArtworkSold(uint256 indexed id, address buyer);
    event ArtworkUnsold(uint256 indexed id);

    modifier onlyAuctioneer() {
        require(isAuctioneer[msg.sender] || msg.sender == owner(), "Not auctioneer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalHammerTotal = FHE.asEuint64(0);
        _totalConsignorProceeds = FHE.asEuint64(0);
        FHE.allowThis(_totalHammerTotal);
        FHE.allowThis(_totalConsignorProceeds);
        isAuctioneer[msg.sender] = true;
    }

    function addAuctioneer(address a) external onlyOwner { isAuctioneer[a] = true; }
    function registerConsignor(address c) external onlyOwner { isConsignor[c] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function consignArtwork(
        string calldata artist,
        string calldata title,
        uint256 yearCreated,
        ArtworkMedium medium,
        string calldata dimensions,
        externalEuint64 encReserve, bytes calldata resProof,
        externalEuint64 encEstLow, bytes calldata elProof,
        externalEuint64 encEstHigh, bytes calldata ehProof,
        externalEuint32 encPremium, bytes calldata prProof,
        uint256 auctionTimestamp
    ) external whenNotPaused returns (uint256 id) {
        require(isConsignor[msg.sender], "Not consignor");
        euint64 reserve = FHE.fromExternal(encReserve, resProof);
        euint64 estLow = FHE.fromExternal(encEstLow, elProof);
        euint64 estHigh = FHE.fromExternal(encEstHigh, ehProof);
        euint32 premium = FHE.fromExternal(encPremium, prProof);
        id = artworkCount++;
        Artwork storage _s0 = artworks[id];
        _s0.consignor = msg.sender;
        _s0.artistName = artist;
        _s0.title = title;
        _s0.yearCreated = yearCreated;
        _s0.medium = medium;
        _s0.dimensions = dimensions;
        _s0.reservePriceUSD = reserve;
        _s0.estimateLowUSD = estLow;
        _s0.estimateHighUSD = estHigh;
        _s0.hammerPriceUSD = FHE.asEuint64(0);
        _s0.premiumRateBps = premium;
        _s0.sellerProceedsUSD = FHE.asEuint64(0);
        _s0.status = SaleStatus.Consigned;
        _s0.auctionDate = auctionTimestamp;
        FHE.allowThis(artworks[id].reservePriceUSD);
        FHE.allow(artworks[id].reservePriceUSD, msg.sender);
        FHE.allowThis(artworks[id].estimateLowUSD);
        FHE.allowThis(artworks[id].estimateHighUSD);
        FHE.allowThis(artworks[id].hammerPriceUSD);
        FHE.allowThis(artworks[id].premiumRateBps);
        FHE.allowThis(artworks[id].sellerProceedsUSD);
        emit ArtworkConsigned(id, artist, title);
    }

    function openAuction(uint256 artworkId) external onlyAuctioneer {
        artworks[artworkId].status = SaleStatus.InAuction;
    }

    function placeBid(
        uint256 artworkId,
        externalEuint64 encBid, bytes calldata proof
    ) external whenNotPaused nonReentrant {
        Artwork storage a = artworks[artworkId];
        require(a.status == SaleStatus.InAuction, "Not in auction");
        euint64 bid = FHE.fromExternal(encBid, proof);
        ebool aboveReserve = FHE.ge(bid, a.reservePriceUSD);
        euint64 validBid = FHE.select(aboveReserve, bid, FHE.asEuint64(0));
        bids[artworkId].push(Bid({ artworkId: artworkId, bidder: msg.sender, bidAmountUSD: validBid, winning: false }));
        totalBidCount++;
        FHE.allowThis(validBid);
        FHE.allow(validBid, msg.sender);
        emit BidPlaced(artworkId, msg.sender);
    }

    function hammer(uint256 artworkId, uint256 winningBidIndex) external onlyAuctioneer nonReentrant {
        Artwork storage a = artworks[artworkId];
        require(a.status == SaleStatus.InAuction, "Not in auction");
        Bid storage winBid = bids[artworkId][winningBidIndex];
        winBid.winning = true;
        euint64 hammer_ = winBid.bidAmountUSD;
        // seller proceeds = hammer * (1 - 15% commission) simplified
        euint64 proceeds = FHE.sub(hammer_, FHE.asEuint64(0)); // commission deducted off-chain
        a.hammerPriceUSD = hammer_;
        a.sellerProceedsUSD = proceeds;
        a.status = SaleStatus.Sold;
        _totalHammerTotal = FHE.add(_totalHammerTotal, hammer_);
        _totalConsignorProceeds = FHE.add(_totalConsignorProceeds, proceeds);
        FHE.allowThis(a.hammerPriceUSD);
        FHE.allow(a.hammerPriceUSD, winBid.bidder);
        FHE.allow(a.hammerPriceUSD, a.consignor);
        FHE.allowThis(a.sellerProceedsUSD);
        FHE.allow(a.sellerProceedsUSD, a.consignor);
        FHE.allowThis(_totalHammerTotal);
        FHE.allowThis(_totalConsignorProceeds);
        emit ArtworkSold(artworkId, winBid.bidder);
    }

    function passLot(uint256 artworkId) external onlyAuctioneer {
        artworks[artworkId].status = SaleStatus.Unsold;
        emit ArtworkUnsold(artworkId);
    }

    function allowGalleryStats(address viewer) external onlyOwner {
        FHE.allow(_totalHammerTotal, viewer);
        FHE.allow(_totalConsignorProceeds, viewer);
    }
}
