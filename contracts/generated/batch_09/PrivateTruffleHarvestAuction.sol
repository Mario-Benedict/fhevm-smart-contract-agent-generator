// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateTruffleHarvestAuction
/// @notice Encrypted truffle harvest auction platform: hidden yield estimates, confidential
///         grade/provenance scoring, private reserve prices for top grades, and encrypted
///         buyer allocation tracking.
contract PrivateTruffleHarvestAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum TruffleSpecies { BlackPerigord, WhiteAlba, SummerTruffle, Burgundy, Oregon }
    enum GradeClass { ExtraClass, ClassOne, ClassTwo, Industrial }

    struct HarvestLot {
        address producer;
        TruffleSpecies species;
        GradeClass gradeClass;
        string regionRef;
        uint32 harvestYear;
        euint32 netWeightGrams;        // encrypted harvest weight
        euint64 reservePricePerKgUSD;  // encrypted reserve price per kg
        euint16 aromaScoreBps;         // encrypted aroma/quality score
        euint16 moistureContentBps;    // encrypted moisture %
        euint64 totalLotValueUSD;      // encrypted lot value
        bool auctionClosed;
    }

    struct TruffleBid {
        uint256 lotId;
        address buyer;
        euint32 desiredWeightGrams;    // encrypted bid weight
        euint64 offerPricePerKgUSD;    // encrypted bid price per kg
        euint64 totalBidUSD;           // encrypted total bid
        bool accepted;
    }

    mapping(uint256 => HarvestLot) private lots;
    mapping(uint256 => TruffleBid) private bids;
    mapping(address => bool) public isTruffleAuctioneer;

    uint256 public lotCount;
    uint256 public bidCount;
    euint64 private _totalAuctionValueUSD;
    euint32 private _totalVolumeSoldGrams;

    event LotCreated(uint256 indexed id, TruffleSpecies species, GradeClass gradeClass);
    event BidPlaced(uint256 indexed bidId, uint256 lotId);
    event BidAccepted(uint256 indexed bidId);

    modifier onlyAuctioneer() {
        require(isTruffleAuctioneer[msg.sender] || msg.sender == owner(), "Not auctioneer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAuctionValueUSD = FHE.asEuint64(0);
        _totalVolumeSoldGrams = FHE.asEuint32(0);
        FHE.allowThis(_totalAuctionValueUSD);
        FHE.allowThis(_totalVolumeSoldGrams);
        isTruffleAuctioneer[msg.sender] = true;
    }

    function addAuctioneer(address a) external onlyOwner { isTruffleAuctioneer[a] = true; }

    function createLot(
        TruffleSpecies species, GradeClass gradeClass, string calldata regionRef, uint32 harvestYear,
        externalEuint32 encWeight, bytes calldata wProof,
        externalEuint64 encReserve, bytes calldata rProof,
        externalEuint16 encAroma, bytes calldata aProof,
        externalEuint16 encMoisture, bytes calldata mProof
    ) external returns (uint256 id) {
        euint32 weight = FHE.fromExternal(encWeight, wProof);
        euint64 reserve = FHE.fromExternal(encReserve, rProof);
        euint16 aroma = FHE.fromExternal(encAroma, aProof);
        euint16 moisture = FHE.fromExternal(encMoisture, mProof);
        euint64 lotValue = FHE.mul(FHE.asEuint64(1), reserve);
        id = lotCount++;
        lots[id].producer = msg.sender;
        lots[id].species = species;
        lots[id].gradeClass = gradeClass;
        lots[id].regionRef = regionRef;
        lots[id].harvestYear = harvestYear;
        lots[id].netWeightGrams = weight;
        lots[id].reservePricePerKgUSD = reserve;
        lots[id].aromaScoreBps = aroma;
        lots[id].moistureContentBps = moisture;
        lots[id].totalLotValueUSD = lotValue;
        lots[id].auctionClosed = false;
        FHE.allowThis(lots[id].netWeightGrams); FHE.allow(lots[id].netWeightGrams, msg.sender);
        FHE.allowThis(lots[id].reservePricePerKgUSD);
        FHE.allowThis(lots[id].aromaScoreBps);
        FHE.allowThis(lots[id].moistureContentBps);
        FHE.allowThis(lots[id].totalLotValueUSD); FHE.allow(lots[id].totalLotValueUSD, msg.sender);
        emit LotCreated(id, species, gradeClass);
    }

    function placeBid(
        uint256 lotId,
        externalEuint32 encDesiredWeight, bytes calldata dwProof,
        externalEuint64 encOfferPrice, bytes calldata opProof
    ) external returns (uint256 bidId) {
        require(!lots[lotId].auctionClosed, "Auction closed");
        euint32 desiredWeight = FHE.fromExternal(encDesiredWeight, dwProof);
        euint64 offerPrice = FHE.fromExternal(encOfferPrice, opProof);
        euint64 totalBid = FHE.mul(FHE.asEuint64(1), offerPrice);
        bidId = bidCount++;
        bids[bidId] = TruffleBid({
            lotId: lotId, buyer: msg.sender, desiredWeightGrams: desiredWeight,
            offerPricePerKgUSD: offerPrice, totalBidUSD: totalBid, accepted: false
        });
        FHE.allowThis(bids[bidId].desiredWeightGrams); FHE.allow(bids[bidId].desiredWeightGrams, msg.sender);
        FHE.allowThis(bids[bidId].offerPricePerKgUSD); FHE.allow(bids[bidId].offerPricePerKgUSD, msg.sender);
        FHE.allowThis(bids[bidId].totalBidUSD); FHE.allow(bids[bidId].totalBidUSD, msg.sender); FHE.allow(bids[bidId].totalBidUSD, lots[lotId].producer);
        emit BidPlaced(bidId, lotId);
    }

    function acceptBid(uint256 bidId) external onlyAuctioneer nonReentrant {
        TruffleBid storage b = bids[bidId];
        HarvestLot storage l = lots[b.lotId];
        require(!b.accepted && !l.auctionClosed, "Invalid state");
        ebool reserveMet = FHE.ge(b.offerPricePerKgUSD, l.reservePricePerKgUSD);
        euint64 settledBid = FHE.select(reserveMet, b.totalBidUSD, FHE.asEuint64(0));
        b.accepted = true;
        _totalAuctionValueUSD = FHE.add(_totalAuctionValueUSD, settledBid);
        _totalVolumeSoldGrams = FHE.add(_totalVolumeSoldGrams, b.desiredWeightGrams);
        FHE.allow(b.offerPricePerKgUSD, l.producer);
        FHE.allowThis(_totalAuctionValueUSD);
        FHE.allowThis(_totalVolumeSoldGrams);
        emit BidAccepted(bidId);
    }

    function closeAuction(uint256 lotId) external onlyAuctioneer {
        lots[lotId].auctionClosed = true;
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalAuctionValueUSD, viewer);
        FHE.allow(_totalVolumeSoldGrams, viewer);
    }
}
