// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionRealEstateDistressed
/// @notice Blind auction for distressed real estate assets where bid amounts and
///         the reserve price are both encrypted. Winning bid must exceed hidden reserve.
///         Due diligence scores (encrypted) can disqualify unqualified bidders.
contract AuctionRealEstateDistressed is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Property {
        string address_;
        string description;
        euint64 reservePrice;  // encrypted reserve
        uint256 auctionEnd;
        bool finalized;
        address winner;
        euint64 winningBid;
    }

    struct Bid {
        euint64 amount;
        euint8 dueDiligenceScore; // encrypted lender qualification score
        bool placed;
    }

    mapping(uint256 => Property) private properties;
    uint256 public propertyCount;
    mapping(uint256 => mapping(address => Bid)) private bids;
    mapping(uint256 => address[]) private bidders;
    euint8 private _minDueDiligenceScore;

    event PropertyListed(uint256 indexed id, string addr);
    event BidPlaced(uint256 indexed propertyId, address indexed bidder);
    event AuctionFinalized(uint256 indexed propertyId, address winner);

    constructor(externalEuint8 encMinScore, bytes memory proof) Ownable(msg.sender) {
        _minDueDiligenceScore = FHE.fromExternal(encMinScore, proof);
        FHE.allowThis(_minDueDiligenceScore);
    }

    function listProperty(
        string calldata addr,
        string calldata desc,
        externalEuint64 encReserve, bytes calldata proof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = propertyCount++;
        properties[id].address_ = addr;
        properties[id].description = desc;
        properties[id].reservePrice = FHE.fromExternal(encReserve, proof);
        properties[id].auctionEnd = block.timestamp + auctionDays * 1 days;
        properties[id].winningBid = FHE.asEuint64(0);
        FHE.allowThis(properties[id].reservePrice);
        FHE.allowThis(properties[id].winningBid);
        emit PropertyListed(id, addr);
    }

    function placeBid(
        uint256 propertyId,
        externalEuint64 encBid, bytes calldata bProof,
        externalEuint8 encScore, bytes calldata sProof
    ) external nonReentrant {
        Property storage p = properties[propertyId];
        require(block.timestamp < p.auctionEnd, "Auction ended");
        require(!bids[propertyId][msg.sender].placed, "Already bid");
        euint64 bid = FHE.fromExternal(encBid, bProof);
        euint8 score = FHE.fromExternal(encScore, sProof);
        bids[propertyId][msg.sender] = Bid({ amount: bid, dueDiligenceScore: score, placed: true });
        FHE.allowThis(bids[propertyId][msg.sender].amount);
        FHE.allow(bids[propertyId][msg.sender].amount, msg.sender);
        FHE.allowThis(bids[propertyId][msg.sender].dueDiligenceScore);
        bidders[propertyId].push(msg.sender);
        emit BidPlaced(propertyId, msg.sender);
    }

    function finalizeAuction(uint256 propertyId) external onlyOwner nonReentrant {
        Property storage p = properties[propertyId];
        require(block.timestamp >= p.auctionEnd, "Not ended");
        require(!p.finalized, "Already finalized");
        p.finalized = true;
        address[] storage bs = bidders[propertyId];
        euint64 bestBid = FHE.asEuint64(0);
        address bestBidder = address(0);
        for (uint256 i = 0; i < bs.length; i++) {
            Bid storage b = bids[propertyId][bs[i]];
            ebool qualifies = FHE.ge(b.dueDiligenceScore, _minDueDiligenceScore);
            ebool exceedsReserve = FHE.ge(b.amount, p.reservePrice);
            ebool valid = FHE.and(qualifies, exceedsReserve);
            ebool isBest = FHE.gt(b.amount, bestBid);
            ebool winnerCandidate = FHE.and(valid, isBest);
            bestBid = FHE.select(winnerCandidate, b.amount, bestBid);
            if (FHE.isInitialized(winnerCandidate)) bestBidder = bs[i];
        }
        p.winner = bestBidder;
        p.winningBid = bestBid;
        FHE.allowThis(p.winningBid);
        if (bestBidder != address(0)) FHE.allow(p.winningBid, bestBidder);
        emit AuctionFinalized(propertyId, bestBidder);
    }

    function getWinner(uint256 propertyId) external view returns (address) {
        require(properties[propertyId].finalized, "Not finalized");
        return properties[propertyId].winner;
    }
}
