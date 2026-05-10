// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedBlindDutchAuction
/// @notice Dutch auction variant where starting price and price decay are encrypted.
///         Bidders don't know current price until they commit; settlement is private.
contract EncryptedBlindDutchAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum AuctionPhase { SETUP, ACTIVE, REVEAL, SETTLED, CANCELLED }

    struct AuctionConfig {
        string  itemName;
        address seller;
        euint64 startingPriceUSD;    // encrypted starting price
        euint64 reservePriceUSD;     // encrypted reserve (floor)
        euint64 priceDecayPerBlock;  // encrypted decay rate
        euint64 totalUnits;          // encrypted units available
        euint64 unitsSold;           // encrypted units sold so far
        euint64 totalRevenue;        // encrypted accumulated revenue
        uint256 startBlock;
        uint256 endBlock;
        AuctionPhase phase;
    }

    struct Bid {
        address bidder;
        euint64 priceOffered;        // encrypted committed price
        euint64 unitsBid;            // encrypted quantity
        euint64 totalCommitted;      // encrypted total value
        euint64 unitsAllocated;      // encrypted winning allocation
        euint64 refundAmount;        // encrypted refund
        bool settled;
    }

    mapping(uint256 => AuctionConfig) private auctions;
    mapping(uint256 => mapping(address => Bid)) private bids;
    mapping(uint256 => address[]) private bidderList;
    uint256 public auctionCount;
    euint64 private _platformTotalRevenue;
    euint16 private _platformFeeBps;

    event AuctionCreated(uint256 indexed id, string item);
    event BidPlaced(uint256 indexed id, address bidder);
    event AuctionSettled(uint256 indexed id);
    event RefundIssued(uint256 indexed id, address bidder);

    constructor(uint16 feeBps) Ownable(msg.sender) {
        _platformFeeBps    = FHE.asEuint16(feeBps);
        _platformTotalRevenue = FHE.asEuint64(0);
        FHE.allowThis(_platformFeeBps);
        FHE.allowThis(_platformTotalRevenue);
    }

    function createAuction(
        string calldata itemName,
        externalEuint64 encStart,   bytes calldata startProof,
        externalEuint64 encReserve, bytes calldata resProof,
        externalEuint64 encDecay,   bytes calldata decayProof,
        externalEuint64 encUnits,   bytes calldata unitsProof,
        uint256 durationBlocks
    ) external returns (uint256 auctionId) {
        euint64 startPrice = FHE.fromExternal(encStart,   startProof);
        euint64 reserve    = FHE.fromExternal(encReserve, resProof);
        euint64 decay      = FHE.fromExternal(encDecay,   decayProof);
        euint64 units      = FHE.fromExternal(encUnits,   unitsProof);

        auctionId = auctionCount++;
        auctions[auctionId].itemName = itemName;
        auctions[auctionId].seller = msg.sender;
        auctions[auctionId].startingPriceUSD = startPrice;
        auctions[auctionId].reservePriceUSD = reserve;
        auctions[auctionId].priceDecayPerBlock = decay;
        auctions[auctionId].totalUnits = units;
        auctions[auctionId].unitsSold = FHE.asEuint64(0);
        auctions[auctionId].totalRevenue = FHE.asEuint64(0);
        auctions[auctionId].startBlock = block.number;
        auctions[auctionId].endBlock = block.number + durationBlocks;
        auctions[auctionId].phase = AuctionPhase.ACTIVE;
        FHE.allowThis(auctions[auctionId].startingPriceUSD);
        FHE.allow(auctions[auctionId].startingPriceUSD, msg.sender);
        FHE.allowThis(auctions[auctionId].reservePriceUSD);
        FHE.allow(auctions[auctionId].reservePriceUSD, msg.sender);
        FHE.allowThis(auctions[auctionId].priceDecayPerBlock);
        FHE.allowThis(auctions[auctionId].totalUnits);
        FHE.allow(auctions[auctionId].totalUnits, msg.sender);
        FHE.allowThis(auctions[auctionId].unitsSold);
        FHE.allowThis(auctions[auctionId].totalRevenue);
        FHE.allow(auctions[auctionId].totalRevenue, msg.sender);
        emit AuctionCreated(auctionId, itemName);
    }

    function placeBid(
        uint256 auctionId,
        externalEuint64 encUnits, bytes calldata unitsProof,
        externalEuint64 encPrice, bytes calldata priceProof
    ) external nonReentrant {
        require(auctions[auctionId].phase == AuctionPhase.ACTIVE, "Not active");
        require(block.number <= auctions[auctionId].endBlock, "Auction ended");

        euint64 units = FHE.fromExternal(encUnits, unitsProof);
        euint64 price = FHE.fromExternal(encPrice, priceProof);

        // Verify bid price >= reserve (encrypted comparison)
        ebool aboveReserve = FHE.ge(price, auctions[auctionId].reservePriceUSD);
        euint64 effectivePrice = FHE.select(aboveReserve, price, auctions[auctionId].reservePriceUSD);
        ebool _safeMul36 = FHE.le(effectivePrice, FHE.asEuint64(type(uint32).max));
        euint64 total = FHE.mul(effectivePrice, units);

        bids[auctionId][msg.sender] = Bid({
            bidder: msg.sender,
            priceOffered: effectivePrice,
            unitsBid: units,
            totalCommitted: total,
            unitsAllocated: FHE.asEuint64(0),
            refundAmount: FHE.asEuint64(0),
            settled: false
        });
        bidderList[auctionId].push(msg.sender);

        FHE.allowThis(bids[auctionId][msg.sender].priceOffered);
        FHE.allow(bids[auctionId][msg.sender].priceOffered, msg.sender);
        FHE.allowThis(bids[auctionId][msg.sender].unitsBid);
        FHE.allow(bids[auctionId][msg.sender].unitsBid, msg.sender);
        FHE.allowThis(bids[auctionId][msg.sender].totalCommitted);
        FHE.allow(bids[auctionId][msg.sender].totalCommitted, msg.sender);
        FHE.allowThis(bids[auctionId][msg.sender].unitsAllocated);
        FHE.allowThis(bids[auctionId][msg.sender].refundAmount);
        emit BidPlaced(auctionId, msg.sender);
    }

    function settleBid(uint256 auctionId, address bidder) external {
        require(msg.sender == owner() || msg.sender == auctions[auctionId].seller, "Unauthorized");
        require(!bids[auctionId][bidder].settled, "Already settled");

        Bid storage bid = bids[auctionId][bidder];
        AuctionConfig storage auction = auctions[auctionId];

        // Check remaining capacity
        ebool hasCapacity = FHE.lt(auction.unitsSold, auction.totalUnits);
        euint64 remaining = FHE.select(
            hasCapacity,
            ebool _safeSub165 = FHE.ge(auction.totalUnits, auction.unitsSold);
            FHE.select(_safeSub165, FHE.sub(auction.totalUnits, auction.unitsSold), FHE.asEuint64(0)),
            FHE.asEuint64(0)
        );
        euint64 allocated = FHE.select(
            FHE.le(bid.unitsBid, remaining),
            bid.unitsBid,
            remaining
        );
        euint64 refund = FHE.mul(
            ebool _safeSub166 = FHE.ge(bid.unitsBid, allocated);
            FHE.select(_safeSub166, FHE.sub(bid.unitsBid, allocated), FHE.asEuint64(0)),
            bid.priceOffered
        );
        ebool _safeMul37 = FHE.le(allocated, FHE.asEuint64(type(uint32).max));
        euint64 revenue = FHE.mul(allocated, bid.priceOffered);

        bid.unitsAllocated = allocated;
        bid.refundAmount   = refund;
        bid.settled        = true;

        auction.unitsSold    = FHE.add(auction.unitsSold, allocated);
        auction.totalRevenue = FHE.add(auction.totalRevenue, revenue);
        _platformTotalRevenue = FHE.add(_platformTotalRevenue, revenue);

        FHE.allowThis(bid.unitsAllocated);
        FHE.allow(bid.unitsAllocated, bidder);
        FHE.allowThis(bid.refundAmount);
        FHE.allow(bid.refundAmount, bidder);
        FHE.allowThis(auction.unitsSold);
        FHE.allowThis(auction.totalRevenue);
        FHE.allowThis(_platformTotalRevenue);

        emit AuctionSettled(auctionId);
        if (FHE.isInitialized(refund)) emit RefundIssued(auctionId, bidder);
    }

    function closeAuction(uint256 auctionId) external {
        require(msg.sender == auctions[auctionId].seller || msg.sender == owner(), "Unauthorized");
        require(block.number > auctions[auctionId].endBlock, "Not ended");
        auctions[auctionId].phase = AuctionPhase.SETTLED;
    }

    function allowPlatformView(address viewer) external onlyOwner {
        FHE.allow(_platformTotalRevenue, viewer);
    }
}
