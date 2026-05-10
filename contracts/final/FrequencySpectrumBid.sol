// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title FrequencySpectrumBid - Government spectrum license sealed-bid auction
contract FrequencySpectrumBid is ZamaEthereumConfig, Ownable {
    struct SpectrumLicense {
        string band;
        string region;
        uint256 licenseYears;
        euint64 winningBid;
        eaddress encWinner;
        address revealedWinner;
        uint256 auctionEnd;
        bool awarded;
    }

    struct BidderProfile {
        bool qualified;
        euint64 depositAmount;
    }

    mapping(uint256 => SpectrumLicense) public licenses;
    mapping(uint256 => mapping(address => euint64)) private bids;
    mapping(address => BidderProfile) public bidders;
    uint256 public licenseCount;

    event LicenseOffered(uint256 indexed licenseId, string band, string region);
    event BidderQualified(address indexed bidder);
    event BidPlaced(uint256 indexed licenseId, address indexed bidder);
    event LicenseAwarded(uint256 indexed licenseId, address indexed winner);

    constructor() Ownable(msg.sender) {}

    function qualifyBidder(
        address bidder,
        externalEuint64 encDeposit,
        bytes calldata inputProof
    ) external onlyOwner {
        euint64 deposit = FHE.fromExternal(encDeposit, inputProof);
        euint64 depositWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 depositExposure = FHE.sub(depositWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        bidders[bidder] = BidderProfile({
            qualified: true,
            depositAmount: deposit
        });
        FHE.allowThis(bidders[bidder].depositAmount);
        FHE.allow(bidders[bidder].depositAmount, bidder);
        emit BidderQualified(bidder);
    }

    function offerLicense(
        string calldata band,
        string calldata region,
        uint256 _years,
        uint256 duration
    ) external onlyOwner returns (uint256 licenseId) {
        licenseId = licenseCount++;
        SpectrumLicense storage l = licenses[licenseId];
        l.band = band;
        l.region = region;
        l.licenseYears = _years;
        l.winningBid = FHE.asEuint64(0);
        l.encWinner = FHE.asEaddress(address(0));
        l.auctionEnd = block.timestamp + duration;
        FHE.allowThis(l.winningBid);
        FHE.allowThis(l.encWinner);
        emit LicenseOffered(licenseId, band, region);
    }

    function placeBid(
        uint256 licenseId,
        externalEuint64 encBid,
        bytes calldata inputProof
    ) external {
        require(bidders[msg.sender].qualified, "Not qualified");
        SpectrumLicense storage l = licenses[licenseId];
        require(block.timestamp <= l.auctionEnd, "Ended");
        require(!l.awarded, "Awarded");

        euint64 bid = FHE.fromExternal(encBid, inputProof);
        bids[licenseId][msg.sender] = bid;
        FHE.allowThis(bids[licenseId][msg.sender]);

        ebool isHigher = FHE.gt(bid, l.winningBid);
        l.winningBid = FHE.select(isHigher, bid, l.winningBid);
        l.encWinner = FHE.select(isHigher, FHE.asEaddress(msg.sender), l.encWinner);
        FHE.allowThis(l.winningBid);
        FHE.allowThis(l.encWinner);
        emit BidPlaced(licenseId, msg.sender);
    }

    function awardLicense(uint256 licenseId, address winner) external onlyOwner {
        SpectrumLicense storage l = licenses[licenseId];
        require(block.timestamp > l.auctionEnd, "Not ended");
        require(!l.awarded, "Done");
        l.awarded = true;
        l.revealedWinner = winner;
        FHE.allow(l.winningBid, winner);
        FHE.allow(l.winningBid, owner());
        FHE.allow(l.encWinner, owner());
        emit LicenseAwarded(licenseId, winner);
    }
}
