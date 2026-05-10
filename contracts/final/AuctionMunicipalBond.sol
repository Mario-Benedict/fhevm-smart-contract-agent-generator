// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionMunicipalBond
/// @notice Municipal bond auction where underwriters submit encrypted yield bids.
///         Issuer selects the bid offering the lowest yield (lowest cost of borrowing)
///         while maintaining encrypted minimum credit requirements.
contract AuctionMunicipalBond is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct BondOffering {
        string municipalityName;
        euint64 faceValueTotal;     // encrypted total face value
        euint16 maxYieldBps;        // encrypted max acceptable yield (ceiling)
        uint256 maturityYears;
        uint256 auctionEnd;
        bool finalized;
        address winner;
        euint16 winningYieldBps;
        euint64 winningAmount;
    }

    struct UnderwriterBid {
        euint16 yieldBps;        // encrypted yield offered in bps
        euint64 purchaseAmount;  // encrypted amount willing to purchase
        euint8 creditRating;     // encrypted underwriter credit rating
        bool placed;
    }

    mapping(uint256 => BondOffering) private offerings;
    uint256 public offeringCount;
    mapping(uint256 => mapping(address => UnderwriterBid)) private bids;
    mapping(uint256 => address[]) private underwriters;
    mapping(address => bool) public isApprovedUnderwriter;
    euint8 private _minCreditRating;

    event OfferingCreated(uint256 indexed id, string municipality);
    event BidSubmitted(uint256 indexed id, address underwriter);
    event BondAwarded(uint256 indexed id, address winner);

    constructor(externalEuint8 encMinCredit, bytes memory proof) Ownable(msg.sender) {
        _minCreditRating = FHE.fromExternal(encMinCredit, proof);
        FHE.allowThis(_minCreditRating);
    }

    function approveUnderwriter(address u) external onlyOwner { isApprovedUnderwriter[u] = true; }

    function createOffering(
        string calldata munName, uint256 maturityYears,
        externalEuint64 encFace, bytes calldata fProof,
        externalEuint16 encMaxYield, bytes calldata yProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = offeringCount++;
        offerings[id].municipalityName = munName;
        offerings[id].maturityYears = maturityYears;
        offerings[id].faceValueTotal = FHE.fromExternal(encFace, fProof);
        offerings[id].maxYieldBps = FHE.fromExternal(encMaxYield, yProof);
        offerings[id].auctionEnd = block.timestamp + auctionDays * 1 days;
        offerings[id].winningYieldBps = FHE.asEuint16(0);
        offerings[id].winningAmount = FHE.asEuint64(0);
        FHE.allowThis(offerings[id].faceValueTotal);
        FHE.allowThis(offerings[id].maxYieldBps);
        FHE.allowThis(offerings[id].winningYieldBps);
        FHE.allowThis(offerings[id].winningAmount);
        emit OfferingCreated(id, munName);
    }

    function submitBid(
        uint256 offeringId,
        externalEuint16 encYield, bytes calldata yProof,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint8 encCredit, bytes calldata cProof
    ) external nonReentrant {
        require(isApprovedUnderwriter[msg.sender], "Not approved");
        BondOffering storage o = offerings[offeringId];
        require(block.timestamp < o.auctionEnd, "Closed");
        require(!bids[offeringId][msg.sender].placed, "Already bid");
        bids[offeringId][msg.sender] = UnderwriterBid({
            yieldBps: FHE.fromExternal(encYield, yProof),
            purchaseAmount: FHE.fromExternal(encAmount, aProof),
            creditRating: FHE.fromExternal(encCredit, cProof),
            placed: true
        });
        FHE.allowThis(bids[offeringId][msg.sender].yieldBps);
        FHE.allowThis(bids[offeringId][msg.sender].purchaseAmount);
        FHE.allowThis(bids[offeringId][msg.sender].creditRating);
        underwriters[offeringId].push(msg.sender);
        emit BidSubmitted(offeringId, msg.sender);
    }

    function finalizeOffering(uint256 offeringId) external onlyOwner nonReentrant {
        BondOffering storage o = offerings[offeringId];
        require(block.timestamp >= o.auctionEnd && !o.finalized, "Cannot finalize");
        o.finalized = true;
        // Select bidder with lowest yield that meets credit criteria
        euint16 bestYield = FHE.asEuint16(type(uint16).max);
        address bestBidder = address(0);
        address[] storage us = underwriters[offeringId];
        for (uint256 i = 0; i < us.length; i++) {
            UnderwriterBid storage b = bids[offeringId][us[i]];
            ebool creditOk = FHE.ge(b.creditRating, _minCreditRating);
            ebool yieldOk = FHE.le(b.yieldBps, o.maxYieldBps);
            ebool valid = FHE.and(creditOk, yieldOk);
            ebool isBest = FHE.lt(b.yieldBps, bestYield);
            ebool winner = FHE.and(valid, isBest);
            bestYield = FHE.select(winner, b.yieldBps, bestYield);
            if (FHE.isInitialized(winner)) {
                bestBidder = us[i];
                o.winningAmount = b.purchaseAmount;
            }
        }
        o.winner = bestBidder;
        o.winningYieldBps = bestYield;
        FHE.allowThis(o.winningYieldBps);
        FHE.allowThis(o.winningAmount);
        if (bestBidder != address(0)) {
            FHE.allow(o.winningYieldBps, bestBidder);
            FHE.allow(o.winningAmount, bestBidder);
        }
        emit BondAwarded(offeringId, bestBidder);
    }
}
