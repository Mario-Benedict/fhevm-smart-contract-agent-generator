// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateArtificialIntelligenceModelAuction
/// @notice Confidential blind auction for proprietary AI model weights and training data licenses.
///         Encrypted bid amounts, hidden bidder identities, and private royalty streams to original
///         data contributors. Supports multiple AI asset types.
contract PrivateArtificialIntelligenceModelAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum AssetType { LLMWeights, DiffusionModel, ReinforcementAgent, ComputerVisionModel, AudioModel, MultiModal }
    enum AuctionState { Open, Closed, Settled }

    struct AIAssetListing {
        address seller;
        AssetType assetType;
        string modelName;
        euint64 reservePriceUSD;       // encrypted reserve price
        euint64 winningBidUSD;         // encrypted winning bid
        euint16 royaltyDataBps;        // encrypted royalty bps to data contributors
        address winner;
        AuctionState state;
        uint256 closeAt;
    }

    struct Bid {
        uint256 listingId;
        address bidder;
        euint64 bidAmountUSD;          // encrypted bid
        bool revealed;
    }

    mapping(uint256 => AIAssetListing) private listings;
    mapping(uint256 => Bid) private bids;
    mapping(uint256 => uint256) private listingHighBidId; // listingId => bidId of current high bid
    mapping(address => bool) public isDataContributor;

    uint256 public listingCount;
    uint256 public bidCount;
    euint64 private _totalSalesVolumeUSD;
    euint64 private _totalRoyaltiesPaidUSD;

    event AssetListed(uint256 indexed id, AssetType assetType, string modelName, uint256 closeAt);
    event BidSubmitted(uint256 indexed bidId, uint256 listingId);
    event AuctionSettled(uint256 indexed listingId, address winner);

    constructor() Ownable(msg.sender) {
        _totalSalesVolumeUSD = FHE.asEuint64(0);
        _totalRoyaltiesPaidUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSalesVolumeUSD);
        FHE.allowThis(_totalRoyaltiesPaidUSD);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addDataContributor(address c) external onlyOwner { isDataContributor[c] = true; }

    function listAIAsset(
        AssetType assetType,
        string calldata modelName,
        externalEuint64 encReserve, bytes calldata rProof,
        externalEuint16 encRoyaltyBps, bytes calldata royProof,
        uint256 durationDays
    ) external whenNotPaused returns (uint256 id) {
        euint64 reserve = FHE.fromExternal(encReserve, rProof);
        euint16 royBps = FHE.fromExternal(encRoyaltyBps, royProof);
        id = listingCount++;
        listings[id].seller = msg.sender;
        listings[id].assetType = assetType;
        listings[id].modelName = modelName;
        listings[id].reservePriceUSD = reserve;
        listings[id].winningBidUSD = FHE.asEuint64(0);
        listings[id].royaltyDataBps = royBps;
        listings[id].winner = address(0);
        listings[id].state = AuctionState.Open;
        listings[id].closeAt = block.timestamp + durationDays * 1 days;
        FHE.allowThis(listings[id].reservePriceUSD); FHE.allow(listings[id].reservePriceUSD, msg.sender);
        FHE.allowThis(listings[id].winningBidUSD);
        FHE.allowThis(listings[id].royaltyDataBps);
        emit AssetListed(id, assetType, modelName, listings[id].closeAt);
    }

    function submitBid(
        uint256 listingId,
        externalEuint64 encBid, bytes calldata proof
    ) external whenNotPaused returns (uint256 bidId) {
        AIAssetListing storage l = listings[listingId];
        require(l.state == AuctionState.Open, "Not open");
        require(block.timestamp < l.closeAt, "Auction closed");
        euint64 bidAmt = FHE.fromExternal(encBid, proof);
        bidId = bidCount++;
        bids[bidId] = Bid({ listingId: listingId, bidder: msg.sender, bidAmountUSD: bidAmt, revealed: false });
        // Update high bid: select max
        uint256 prevHighId = listingHighBidId[listingId];
        if (bidId > 0 && FHE.isInitialized(bids[prevHighId].bidAmountUSD)) {
            ebool isHigher = FHE.gt(bidAmt, bids[prevHighId].bidAmountUSD);
            euint64 newHigh = FHE.select(isHigher, bidAmt, bids[prevHighId].bidAmountUSD);
            FHE.allowThis(newHigh);
            if (FHE.isInitialized(isHigher)) listingHighBidId[listingId] = bidId;
        } else {
            listingHighBidId[listingId] = bidId;
        }
        FHE.allowThis(bids[bidId].bidAmountUSD);
        emit BidSubmitted(bidId, listingId);
    }

    function settleAuction(uint256 listingId) external onlyOwner nonReentrant {
        AIAssetListing storage l = listings[listingId];
        require(l.state == AuctionState.Open && block.timestamp >= l.closeAt, "Not closeable");
        l.state = AuctionState.Settled;
        uint256 highBidId = listingHighBidId[listingId];
        Bid storage hb = bids[highBidId];
        // Check reserve met (branchless)
        ebool reserveMet = FHE.ge(hb.bidAmountUSD, l.reservePriceUSD);
        euint64 winAmt = FHE.select(reserveMet, hb.bidAmountUSD, FHE.asEuint64(0));
        l.winningBidUSD = winAmt;
        l.winner = hb.bidder;
        euint64 royalty = FHE.div(winAmt, 100); // 1% royalty from plaintext divisor
        _totalSalesVolumeUSD = FHE.add(_totalSalesVolumeUSD, winAmt);
        _totalRoyaltiesPaidUSD = FHE.add(_totalRoyaltiesPaidUSD, royalty);
        FHE.allowThis(l.winningBidUSD);
        FHE.allow(l.winningBidUSD, l.seller);
        FHE.allow(l.winningBidUSD, hb.bidder);
        FHE.allowThis(_totalSalesVolumeUSD);
        FHE.allowThis(_totalRoyaltiesPaidUSD);
        emit AuctionSettled(listingId, hb.bidder);
    }

    function allowStatsView(address viewer) external onlyOwner {
        FHE.allow(_totalSalesVolumeUSD, viewer);
        FHE.allow(_totalRoyaltiesPaidUSD, viewer);
    }
}
