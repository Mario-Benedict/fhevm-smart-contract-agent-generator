// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionElectricityCapacity
/// @notice Power capacity market auction where generators bid encrypted MW capacity.
///         Grid operator accepts bids meeting encrypted minimum reliability score.
contract AuctionElectricityCapacity is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct CapacityAuction {
        string region;
        euint32 targetCapacityMW;  // encrypted target MW to procure
        euint64 reservePricePerMW; // encrypted reserve price
        uint256 auctionEnd;
        bool finalized;
        euint32 procuredMW;
        euint64 clearingPrice;
    }

    struct GeneratorBid {
        euint32 offeredMW;
        euint64 bidPricePerMW;
        euint8 reliabilityScore;  // encrypted 0-100
        bool placed;
        bool accepted;
    }

    mapping(uint256 => CapacityAuction) private auctions;
    uint256 public auctionCount;
    mapping(uint256 => mapping(address => GeneratorBid)) private bids;
    mapping(uint256 => address[]) private generators;
    mapping(address => bool) public isRegisteredGenerator;
    euint8 private _minReliabilityScore;

    event AuctionCreated(uint256 indexed id, string region);
    event BidSubmitted(uint256 indexed id, address generator);
    event AuctionCleared(uint256 indexed id);

    constructor(externalEuint8 encMinReliability, bytes memory proof) Ownable(msg.sender) {
        _minReliabilityScore = FHE.fromExternal(encMinReliability, proof);
        FHE.allowThis(_minReliabilityScore);
    }

    function registerGenerator(address gen) external onlyOwner { isRegisteredGenerator[gen] = true; }

    function createAuction(
        string calldata region,
        externalEuint32 encTarget, bytes calldata tProof,
        externalEuint64 encReserve, bytes calldata rProof,
        uint256 daysOpen
    ) external onlyOwner returns (uint256 id) {
        id = auctionCount++;
        auctions[id].region = region;
        auctions[id].targetCapacityMW = FHE.fromExternal(encTarget, tProof);
        auctions[id].reservePricePerMW = FHE.fromExternal(encReserve, rProof);
        auctions[id].auctionEnd = block.timestamp + daysOpen * 1 days;
        auctions[id].procuredMW = FHE.asEuint32(0);
        auctions[id].clearingPrice = FHE.asEuint64(0);
        FHE.allowThis(auctions[id].targetCapacityMW);
        FHE.allowThis(auctions[id].reservePricePerMW);
        FHE.allowThis(auctions[id].procuredMW);
        FHE.allowThis(auctions[id].clearingPrice);
        emit AuctionCreated(id, region);
    }

    function submitBid(
        uint256 auctionId,
        externalEuint32 encMW, bytes calldata mProof,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint8 encReliability, bytes calldata rProof
    ) external nonReentrant {
        require(isRegisteredGenerator[msg.sender], "Not registered");
        CapacityAuction storage a = auctions[auctionId];
        require(block.timestamp < a.auctionEnd, "Closed");
        require(!bids[auctionId][msg.sender].placed, "Already bid");
        bids[auctionId][msg.sender] = GeneratorBid({
            offeredMW: FHE.fromExternal(encMW, mProof),
            bidPricePerMW: FHE.fromExternal(encPrice, pProof),
            reliabilityScore: FHE.fromExternal(encReliability, rProof),
            placed: true, accepted: false
        });
        FHE.allowThis(bids[auctionId][msg.sender].offeredMW);
        FHE.allowThis(bids[auctionId][msg.sender].bidPricePerMW);
        FHE.allowThis(bids[auctionId][msg.sender].reliabilityScore);
        generators[auctionId].push(msg.sender);
        emit BidSubmitted(auctionId, msg.sender);
    }

    function clearAuction(uint256 auctionId) external onlyOwner nonReentrant {
        CapacityAuction storage a = auctions[auctionId];
        require(block.timestamp >= a.auctionEnd && !a.finalized, "Cannot clear");
        a.finalized = true;
        address[] storage gens = generators[auctionId];
        euint32 totalProcured = FHE.asEuint32(0);
        euint64 maxClearingPrice = FHE.asEuint64(0);
        for (uint256 i = 0; i < gens.length; i++) {
            GeneratorBid storage b = bids[auctionId][gens[i]];
            ebool relOk = FHE.ge(b.reliabilityScore, _minReliabilityScore);
            ebool priceOk = FHE.le(b.bidPricePerMW, a.reservePricePerMW);
            ebool valid = FHE.and(relOk, priceOk);
            ebool stillNeeded = FHE.lt(totalProcured, a.targetCapacityMW);
            ebool accept = FHE.and(valid, stillNeeded);
            euint32 acceptedMW = FHE.select(accept, b.offeredMW, FHE.asEuint32(0));
            totalProcured = FHE.add(totalProcured, acceptedMW);
            maxClearingPrice = FHE.select(
                FHE.and(accept, FHE.gt(b.bidPricePerMW, maxClearingPrice)),
                b.bidPricePerMW, maxClearingPrice
            );
            b.accepted = FHE.isInitialized(accept);
            FHE.allowThis(totalProcured);
        }
        a.procuredMW = totalProcured;
        a.clearingPrice = maxClearingPrice;
        FHE.allowThis(a.procuredMW);
        FHE.allowThis(a.clearingPrice);
        emit AuctionCleared(auctionId);
    }

    function allowAuctionData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(auctions[id].procuredMW, viewer);
        FHE.allow(auctions[id].clearingPrice, viewer);
    }
}
