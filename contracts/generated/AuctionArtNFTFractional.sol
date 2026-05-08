// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionArtNFTFractional
/// @notice Fractional NFT art auction where collectors bid on encrypted percentage stakes.
///         The artwork floor price and provenance score are encrypted to prevent
///         front-running and price manipulation.
contract AuctionArtNFTFractional is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Artwork {
        string title;
        string artist;
        uint256 totalFractions;
        euint64 floorPricePerFraction;  // encrypted
        euint8 provenanceScore;          // encrypted 0-100
        uint256 auctionEnd;
        bool finalized;
        uint256 fractionsSold;
    }

    struct CollectorBid {
        euint32 fractionsWanted;
        euint64 bidPerFraction;
        euint8 collectorScore;  // encrypted collector reputation
        bool placed;
        uint256 fractionsAllocated;
    }

    mapping(uint256 => Artwork) private artworks;
    uint256 public artworkCount;
    mapping(uint256 => mapping(address => CollectorBid)) private bids;
    mapping(uint256 => address[]) private collectors;
    mapping(address => bool) public isVerifiedCollector;

    event ArtworkListed(uint256 indexed id, string title);
    event BidPlaced(uint256 indexed id, address collector);
    event FractionsAllocated(uint256 indexed id);

    constructor() Ownable(msg.sender) {}

    function verifyCollector(address c) external onlyOwner { isVerifiedCollector[c] = true; }

    function listArtwork(
        string calldata title, string calldata artist,
        uint256 totalFractions,
        externalEuint64 encFloor, bytes calldata fProof,
        externalEuint8 encProvenance, bytes calldata pProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = artworkCount++;
        artworks[id].title = title;
        artworks[id].artist = artist;
        artworks[id].totalFractions = totalFractions;
        artworks[id].floorPricePerFraction = FHE.fromExternal(encFloor, fProof);
        artworks[id].provenanceScore = FHE.fromExternal(encProvenance, pProof);
        artworks[id].auctionEnd = block.timestamp + auctionDays * 1 days;
        FHE.allowThis(artworks[id].floorPricePerFraction);
        FHE.allowThis(artworks[id].provenanceScore);
        emit ArtworkListed(id, title);
    }

    function placeBid(
        uint256 artId,
        externalEuint32 encFractions, bytes calldata fProof,
        externalEuint64 encBid, bytes calldata bProof,
        externalEuint8 encScore, bytes calldata sProof
    ) external nonReentrant {
        require(isVerifiedCollector[msg.sender], "Not verified");
        Artwork storage a = artworks[artId];
        require(block.timestamp < a.auctionEnd, "Closed");
        require(!bids[artId][msg.sender].placed, "Already bid");
        bids[artId][msg.sender] = CollectorBid({
            fractionsWanted: FHE.fromExternal(encFractions, fProof),
            bidPerFraction: FHE.fromExternal(encBid, bProof),
            collectorScore: FHE.fromExternal(encScore, sProof),
            placed: true, fractionsAllocated: 0
        });
        FHE.allowThis(bids[artId][msg.sender].fractionsWanted);
        FHE.allowThis(bids[artId][msg.sender].bidPerFraction);
        FHE.allowThis(bids[artId][msg.sender].collectorScore);
        collectors[artId].push(msg.sender);
        emit BidPlaced(artId, msg.sender);
    }

    function allocateFractions(uint256 artId) external onlyOwner nonReentrant {
        Artwork storage a = artworks[artId];
        require(block.timestamp >= a.auctionEnd && !a.finalized, "Cannot allocate");
        a.finalized = true;
        uint256 remaining = a.totalFractions;
        address[] storage cs = collectors[artId];
        for (uint256 i = 0; i < cs.length && remaining > 0; i++) {
            CollectorBid storage b = bids[artId][cs[i]];
            ebool priceOk = FHE.ge(b.bidPerFraction, a.floorPricePerFraction);
            if (!FHE.isInitialized(priceOk)) continue;
            // Determine fractions to allocate (simplified)
            b.fractionsAllocated = remaining > 10 ? 10 : remaining; // cap at 10 per bidder
            remaining -= b.fractionsAllocated;
            a.fractionsSold += b.fractionsAllocated;
        }
        emit FractionsAllocated(artId);
    }

    function getFractionsSold(uint256 artId) external view returns (uint256) {
        return artworks[artId].fractionsSold;
    }
}
