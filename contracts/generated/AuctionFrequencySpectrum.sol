// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionFrequencySpectrum
/// @notice Telecom spectrum auction where operators bid on frequency bands.
///         Bid amounts and bandwidth requirements are encrypted. Regulator
///         enforces encrypted minimum technical requirements per bidder.
contract AuctionFrequencySpectrum is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct FrequencyBand {
        string bandName;     // e.g. "700 MHz", "3.5 GHz"
        uint32 bandwidthMhz;
        euint64 reservePrice;
        uint256 auctionEnd;
        bool finalized;
        address winner;
        euint64 winningBid;
    }

    struct OperatorBid {
        euint64 bidAmount;
        euint32 coverageCommitmentPct; // encrypted: % coverage promised
        euint8 technicalScore;          // encrypted technical capability score
        bool placed;
    }

    mapping(uint256 => FrequencyBand) private bands;
    uint256 public bandCount;
    mapping(uint256 => mapping(address => OperatorBid)) private bids;
    mapping(uint256 => address[]) private bidders;
    mapping(address => bool) public isLicensedOperator;
    euint8 private _minTechScore;

    event BandListed(uint256 indexed id, string bandName);
    event OperatorBidPlaced(uint256 indexed bandId, address indexed operator);
    event SpectrumAwarded(uint256 indexed bandId, address winner);

    constructor(externalEuint8 encMinTech, bytes memory proof) Ownable(msg.sender) {
        _minTechScore = FHE.fromExternal(encMinTech, proof);
        FHE.allowThis(_minTechScore);
    }

    function licenseOperator(address op) external onlyOwner { isLicensedOperator[op] = true; }

    function listBand(
        string calldata bandName, uint32 bandwidth,
        externalEuint64 encReserve, bytes calldata proof,
        uint256 daysOpen
    ) external onlyOwner returns (uint256 id) {
        id = bandCount++;
        bands[id].bandName = bandName;
        bands[id].bandwidthMhz = bandwidth;
        bands[id].reservePrice = FHE.fromExternal(encReserve, proof);
        bands[id].auctionEnd = block.timestamp + daysOpen * 1 days;
        bands[id].winningBid = FHE.asEuint64(0);
        FHE.allowThis(bands[id].reservePrice);
        FHE.allowThis(bands[id].winningBid);
        emit BandListed(id, bandName);
    }

    function placeBid(
        uint256 bandId,
        externalEuint64 encBid, bytes calldata bProof,
        externalEuint32 encCoverage, bytes calldata cProof,
        externalEuint8 encTech, bytes calldata tProof
    ) external nonReentrant {
        require(isLicensedOperator[msg.sender], "Not licensed");
        FrequencyBand storage band = bands[bandId];
        require(block.timestamp < band.auctionEnd, "Closed");
        require(!bids[bandId][msg.sender].placed, "Already bid");
        bids[bandId][msg.sender] = OperatorBid({
            bidAmount: FHE.fromExternal(encBid, bProof),
            coverageCommitmentPct: FHE.fromExternal(encCoverage, cProof),
            technicalScore: FHE.fromExternal(encTech, tProof),
            placed: true
        });
        FHE.allowThis(bids[bandId][msg.sender].bidAmount);
        FHE.allowThis(bids[bandId][msg.sender].coverageCommitmentPct);
        FHE.allowThis(bids[bandId][msg.sender].technicalScore);
        bidders[bandId].push(msg.sender);
        emit OperatorBidPlaced(bandId, msg.sender);
    }

    function finalizeAuction(uint256 bandId) external onlyOwner nonReentrant {
        FrequencyBand storage band = bands[bandId];
        require(block.timestamp >= band.auctionEnd, "Not ended");
        require(!band.finalized, "Already finalized");
        band.finalized = true;
        address[] storage bs = bidders[bandId];
        euint64 bestBid = FHE.asEuint64(0);
        address bestBidder = address(0);
        for (uint256 i = 0; i < bs.length; i++) {
            OperatorBid storage ob = bids[bandId][bs[i]];
            ebool techOk = FHE.ge(ob.technicalScore, _minTechScore);
            ebool meetsReserve = FHE.ge(ob.bidAmount, band.reservePrice);
            ebool valid = FHE.and(techOk, meetsReserve);
            ebool isBest = FHE.gt(ob.bidAmount, bestBid);
            ebool winner = FHE.and(valid, isBest);
            bestBid = FHE.select(winner, ob.bidAmount, bestBid);
            if (FHE.isInitialized(winner)) bestBidder = bs[i];
        }
        band.winner = bestBidder;
        band.winningBid = bestBid;
        FHE.allowThis(band.winningBid);
        if (bestBidder != address(0)) FHE.allow(band.winningBid, bestBidder);
        emit SpectrumAwarded(bandId, bestBidder);
    }

    function getWinner(uint256 bandId) external view returns (address) {
        require(bands[bandId].finalized, "Not finalized");
        return bands[bandId].winner;
    }
}
