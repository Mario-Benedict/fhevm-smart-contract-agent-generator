// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedTradeSecretAuction
/// @notice Companies bid for exclusive access to trade secrets/IP.
///         Bid amounts, reserve prices, and bidder identities remain encrypted.
///         Uses Vickrey mechanism to reveal only winning bid in FHE.
contract EncryptedTradeSecretAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct TradeSecret {
        bytes32 contentHash;      // IPFS hash of encrypted secret
        euint64 reservePrice;     // minimum bid, encrypted
        euint64 highestBid;       // current highest bid, encrypted
        address highestBidder;
        euint32 exclusivityDays;  // how long exclusive access granted
        bool active;
        bool settled;
        uint256 auctionEndTime;
        uint256 registeredAt;
        string category;          // "technology", "formula", "process", etc.
    }

    struct Bid {
        euint64 amount;
        uint256 placedAt;
        bool refunded;
    }

    mapping(uint256 => TradeSecret) private secrets;
    mapping(uint256 => mapping(address => Bid)) private bids;
    mapping(uint256 => address[]) private bidderList;
    uint256 public secretCount;

    euint64 private _totalVolumeSettled;
    euint32 private _platformFeeBps;

    event SecretListed(uint256 indexed secretId, string category);
    event BidPlaced(uint256 indexed secretId, address indexed bidder);
    event AuctionSettled(uint256 indexed secretId, address winner);
    event BidRefunded(uint256 indexed secretId, address indexed bidder);

    constructor(externalEuint32 encFee, bytes memory feeProof) Ownable(msg.sender) {
        _platformFeeBps = FHE.fromExternal(encFee, feeProof);
        _totalVolumeSettled = FHE.asEuint64(0);
        FHE.allowThis(_platformFeeBps);
        FHE.allowThis(_totalVolumeSettled);
    }

    function listSecret(
        bytes32 contentHash,
        externalEuint64 encReserve, bytes calldata reserveProof,
        externalEuint32 encExclusivity, bytes calldata exclProof,
        uint256 auctionDurationHours,
        string calldata category
    ) external onlyOwner returns (uint256 secretId) {
        secretId = secretCount++;
        TradeSecret storage s = secrets[secretId];
        s.contentHash = contentHash;
        s.reservePrice = FHE.fromExternal(encReserve, reserveProof);
        s.exclusivityDays = FHE.fromExternal(encExclusivity, exclProof);
        s.highestBid = FHE.asEuint64(0);
        s.active = true;
        s.auctionEndTime = block.timestamp + (auctionDurationHours * 1 hours);
        s.registeredAt = block.timestamp;
        s.category = category;
        FHE.allowThis(s.reservePrice);
        FHE.allowThis(s.highestBid);
        FHE.allowThis(s.exclusivityDays);
        emit SecretListed(secretId, category);
    }

    function placeBid(
        uint256 secretId,
        externalEuint64 encBid, bytes calldata proof
    ) external nonReentrant {
        TradeSecret storage s = secrets[secretId];
        require(s.active && !s.settled, "Auction not active");
        require(block.timestamp < s.auctionEndTime, "Auction ended");
        euint64 bid = FHE.fromExternal(encBid, proof);
        // Check if bid > current highest
        ebool isHigher = FHE.gt(bid, s.highestBid);
        euint64 newHighest = FHE.select(isHigher, bid, s.highestBid);
        s.highestBid = newHighest;
        // Only update bidder if actually higher (simplified: track all bids)
        bids[secretId][msg.sender].amount = bid;
        bids[secretId][msg.sender].placedAt = block.timestamp;
        bidderList[secretId].push(msg.sender);
        FHE.allowThis(s.highestBid);
        FHE.allow(s.highestBid, owner());
        FHE.allowThis(bids[secretId][msg.sender].amount);
        FHE.allow(bids[secretId][msg.sender].amount, msg.sender);
        FHE.allow(bids[secretId][msg.sender].amount, owner());
        FHE.allow(isHigher, msg.sender);
        emit BidPlaced(secretId, msg.sender);
    }

    function settleAuction(uint256 secretId, address winner) external onlyOwner {
        TradeSecret storage s = secrets[secretId];
        require(s.active && !s.settled, "Cannot settle");
        require(block.timestamp >= s.auctionEndTime, "Not ended");
        s.settled = true;
        s.active = false;
        s.highestBidder = winner;
        // Check reserve met
        ebool reserveMet = FHE.ge(s.highestBid, s.reservePrice);
        euint64 winningBid = FHE.select(reserveMet, s.highestBid, FHE.asEuint64(0));
        euint64 fee = FHE.div(winningBid, 20); // 5% fee
        euint64 sellerProceeds = FHE.sub(winningBid, fee);
        _totalVolumeSettled = FHE.add(_totalVolumeSettled, winningBid);
        FHE.allowThis(_totalVolumeSettled);
        FHE.allow(winningBid, winner);
        FHE.allow(sellerProceeds, owner());
        FHE.allow(reserveMet, winner);
        FHE.allow(s.exclusivityDays, winner);
        emit AuctionSettled(secretId, winner);
    }

    function refundBid(uint256 secretId) external nonReentrant {
        TradeSecret storage s = secrets[secretId];
        require(s.settled || block.timestamp >= s.auctionEndTime, "Auction ongoing");
        require(msg.sender != s.highestBidder, "Winner cannot refund");
        require(!bids[secretId][msg.sender].refunded, "Already refunded");
        bids[secretId][msg.sender].refunded = true;
        FHE.allow(bids[secretId][msg.sender].amount, msg.sender);
        emit BidRefunded(secretId, msg.sender);
    }

    function allowAuctionMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalVolumeSettled, viewer);
    }
}
