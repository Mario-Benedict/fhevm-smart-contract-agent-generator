// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSovereignDebtAuction
/// @notice Government treasury bond auction with confidential bid amounts,
///         encrypted yield requirements, and private winner determination.
///         Supports Dutch auction clearing and multiple-price sealed bid format.
contract EncryptedSovereignDebtAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum AuctionFormat { MULTIPLE_PRICE, DUTCH_UNIFORM }
    enum BondRating { AAA, AA, A, BBB }

    struct BondIssuance {
        string bondSeries;
        AuctionFormat format;
        BondRating rating;
        euint64 totalFaceValueUSD;     // encrypted total issuance size
        euint64 minimumYieldBps;       // encrypted minimum acceptable yield
        euint64 maximumYieldBps;       // encrypted maximum yield ceiling
        euint64 couponRateBps;         // encrypted coupon rate
        euint64 maturityYears;         // encrypted tenor in years
        euint64 totalAllocated;        // encrypted total bonds allocated
        uint256 biddingDeadline;
        bool settled;
        bool active;
    }

    struct BidRecord {
        address bidder;
        uint256 issuanceId;
        euint64 faceValueRequested;   // encrypted bid size
        euint64 yieldRequiredBps;     // encrypted yield requirement
        euint64 allocatedAmount;      // encrypted final allocation
        euint64 clearingYield;        // encrypted clearing yield paid
        bool submitted;
        bool allocated;
    }

    struct BidderKYC {
        euint8 investorClass;   // 0=retail, 1=institutional, 2=primary dealer
        euint64 maxBidCapUSD;
        bool approved;
    }

    mapping(uint256 => BondIssuance) private issuances;
    mapping(bytes32 => BidRecord) private bids; // keccak256(bidder, issuanceId, nonce)
    mapping(address => BidderKYC) private bidderKYC;
    mapping(address => bool) public isPrimaryDealer;
    mapping(uint256 => euint64) private clearingYieldByIssuance;

    uint256 public issuanceCount;
    euint64 private _totalDebtOutstanding;
    euint64 private _weightedAvgYield;

    event BondIssuanceCreated(uint256 indexed id, string series);
    event BidSubmitted(bytes32 indexed bidKey, uint256 indexed issuanceId);
    event AuctionSettled(uint256 indexed issuanceId);
    event BidAllocated(bytes32 indexed bidKey);

    constructor() Ownable(msg.sender) {
        _totalDebtOutstanding = FHE.asEuint64(0);
        _weightedAvgYield = FHE.asEuint64(0);
        FHE.allowThis(_totalDebtOutstanding);
        FHE.allowThis(_weightedAvgYield);
        isPrimaryDealer[msg.sender] = true;
    }

    function registerBidder(
        address bidder,
        externalEuint8 encClass, bytes calldata classProof,
        externalEuint64 encMaxBid, bytes calldata mbProof
    ) external onlyOwner {
        bidderKYC[bidder].investorClass = FHE.fromExternal(encClass, classProof);
        bidderKYC[bidder].maxBidCapUSD = FHE.fromExternal(encMaxBid, mbProof);
        bidderKYC[bidder].approved = true;
        FHE.allowThis(bidderKYC[bidder].investorClass);
        FHE.allow(bidderKYC[bidder].investorClass, bidder);
        FHE.allowThis(bidderKYC[bidder].maxBidCapUSD);
        FHE.allow(bidderKYC[bidder].maxBidCapUSD, bidder);
    }

    function createIssuance(
        string calldata series,
        AuctionFormat format,
        BondRating rating,
        externalEuint64 encTotalFV, bytes calldata tfProof,
        externalEuint64 encMinYield, bytes calldata myProof,
        externalEuint64 encMaxYield, bytes calldata mxyProof,
        externalEuint64 encCoupon, bytes calldata cProof,
        externalEuint64 encMaturity, bytes calldata matProof,
        uint256 deadline
    ) external onlyOwner returns (uint256 id) {
        id = issuanceCount++;
        BondIssuance storage bi = issuances[id];
        bi.bondSeries = series;
        bi.format = format;
        bi.rating = rating;
        bi.totalFaceValueUSD = FHE.fromExternal(encTotalFV, tfProof);
        bi.minimumYieldBps = FHE.fromExternal(encMinYield, myProof);
        bi.maximumYieldBps = FHE.fromExternal(encMaxYield, mxyProof);
        bi.couponRateBps = FHE.fromExternal(encCoupon, cProof);
        bi.maturityYears = FHE.fromExternal(encMaturity, matProof);
        bi.totalAllocated = FHE.asEuint64(0);
        bi.biddingDeadline = deadline;
        bi.active = true;
        FHE.allowThis(bi.totalFaceValueUSD);
        FHE.allowThis(bi.minimumYieldBps);
        FHE.allowThis(bi.maximumYieldBps);
        FHE.allowThis(bi.couponRateBps);
        FHE.allowThis(bi.maturityYears);
        FHE.allowThis(bi.totalAllocated);
        emit BondIssuanceCreated(id, series);
    }

    function submitBid(
        uint256 issuanceId,
        uint256 nonce,
        externalEuint64 encFaceValue, bytes calldata fvProof,
        externalEuint64 encYield, bytes calldata yProof
    ) external nonReentrant returns (bytes32 bidKey) {
        require(bidderKYC[msg.sender].approved, "Not approved bidder");
        BondIssuance storage bi = issuances[issuanceId];
        require(bi.active && !bi.settled, "Auction not active");
        require(block.timestamp < bi.biddingDeadline, "Bidding closed");
        euint64 fv = FHE.fromExternal(encFaceValue, fvProof);
        euint64 yld = FHE.fromExternal(encYield, yProof);
        // Verify bid within cap
        ebool withinCap = FHE.le(fv, bidderKYC[msg.sender].maxBidCapUSD);
        euint64 actualFV = FHE.select(withinCap, fv, bidderKYC[msg.sender].maxBidCapUSD);
        // Yield must be within bounds
        ebool yieldValid = FHE.and(FHE.ge(yld, bi.minimumYieldBps), FHE.le(yld, bi.maximumYieldBps));
        euint64 actualYield = FHE.select(yieldValid, yld, bi.minimumYieldBps);
        bidKey = keccak256(abi.encodePacked(msg.sender, issuanceId, nonce));
        BidRecord storage br = bids[bidKey];
        br.bidder = msg.sender;
        br.issuanceId = issuanceId;
        br.faceValueRequested = actualFV;
        br.yieldRequiredBps = actualYield;
        br.allocatedAmount = FHE.asEuint64(0);
        br.clearingYield = FHE.asEuint64(0);
        br.submitted = true;
        FHE.allowThis(br.faceValueRequested);
        FHE.allowThis(br.yieldRequiredBps);
        FHE.allowThis(br.allocatedAmount);
        emit BidSubmitted(bidKey, issuanceId);
    }

    function allocateBid(
        bytes32 bidKey,
        externalEuint64 encAllocated, bytes calldata alProof,
        externalEuint64 encClearingYield, bytes calldata cyProof
    ) external onlyOwner {
        BidRecord storage br = bids[bidKey];
        require(br.submitted && !br.allocated, "Invalid bid");
        BondIssuance storage bi = issuances[br.issuanceId];
        euint64 allocated = FHE.fromExternal(encAllocated, alProof);
        euint64 clearYield = FHE.fromExternal(encClearingYield, cyProof);
        // Ensure we don't over-allocate
        euint64 remaining = FHE.sub(bi.totalFaceValueUSD, bi.totalAllocated);
        ebool hasRoom = FHE.ge(remaining, allocated);
        euint64 actual = FHE.select(hasRoom, allocated, remaining);
        br.allocatedAmount = actual;
        br.clearingYield = clearYield;
        br.allocated = true;
        bi.totalAllocated = FHE.add(bi.totalAllocated, actual);
        _totalDebtOutstanding = FHE.add(_totalDebtOutstanding, actual);
        FHE.allowThis(br.allocatedAmount);
        FHE.allow(br.allocatedAmount, br.bidder);
        FHE.allowThis(br.clearingYield);
        FHE.allow(br.clearingYield, br.bidder);
        FHE.allowThis(bi.totalAllocated);
        FHE.allowThis(_totalDebtOutstanding);
        emit BidAllocated(bidKey);
    }

    function settleAuction(uint256 issuanceId) external onlyOwner {
        issuances[issuanceId].settled = true;
        emit AuctionSettled(issuanceId);
    }

    function allowDebtStats(address analyst) external onlyOwner {
        FHE.allow(_totalDebtOutstanding, analyst);
        FHE.allow(_weightedAvgYield, analyst);
    }

    function addPrimaryDealer(address pd) external onlyOwner { isPrimaryDealer[pd] = true; }
}
