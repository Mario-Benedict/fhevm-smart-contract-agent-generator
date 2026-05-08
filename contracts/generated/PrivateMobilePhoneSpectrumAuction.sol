// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMobilePhoneSpectrumAuction
/// @notice Encrypted mobile spectrum auction: hidden bid amounts per frequency band,
///         confidential reserve prices, private bidder financial qualification scores,
///         and encrypted regional coverage obligation assessments.
contract PrivateMobilePhoneSpectrumAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SpectrumBand { Band700MHz, Band850MHz, Band1800MHz, Band2100MHz, Band2600MHz, Band3500MHz, Band26GHz }
    enum LicenseStatus { Available, BidPhase, Awarded, Inactive }

    struct SpectrumLicense {
        string regulatoryRef;
        SpectrumBand band;
        string geographicRegion;
        uint32 bandwidthMHz;
        uint32 licenseDurationYears;
        euint64 reservePriceUSD;       // encrypted reserve price
        euint64 awardedPriceUSD;       // encrypted winning bid
        euint64 coverageObligationBps; // encrypted coverage obligation
        address awardedBidder;
        LicenseStatus status;
    }

    struct SpectrumBid {
        uint256 licenseId;
        address telecomOperator;
        euint64 bidAmountUSD;          // encrypted bid
        euint16 financialQualScore;    // encrypted financial capacity score
        euint16 networkReadinessScore; // encrypted network deployment readiness
        bool accepted;
    }

    mapping(uint256 => SpectrumLicense) private licenses;
    mapping(uint256 => SpectrumBid) private bids;
    mapping(address => bool) public isRegulator;
    mapping(address => bool) public isTelecomOperator;

    uint256 public licenseCount;
    uint256 public bidCount;
    euint64 private _totalAuctionRevenueUSD;

    event LicenseCreated(uint256 indexed id, SpectrumBand band, string region);
    event BidSubmitted(uint256 indexed bidId, uint256 licenseId);
    event LicenseAwarded(uint256 indexed licenseId, address telecomOperator);

    modifier onlyRegulator() {
        require(isRegulator[msg.sender] || msg.sender == owner(), "Not regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAuctionRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalAuctionRevenueUSD);
        isRegulator[msg.sender] = true;
        isTelecomOperator[msg.sender] = true;
    }

    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }
    function addOperator(address op) external onlyOwner { isTelecomOperator[op] = true; }

    function createLicense(
        string calldata regulatoryRef, SpectrumBand band, string calldata region,
        uint32 bandwidthMHz, uint32 licenseDurationYears,
        externalEuint64 encReserve, bytes calldata rProof,
        externalEuint64 encCoverage, bytes calldata covProof
    ) external onlyRegulator returns (uint256 id) {
        euint64 reserve = FHE.fromExternal(encReserve, rProof);
        euint64 coverage = FHE.fromExternal(encCoverage, covProof);
        id = licenseCount++;
        licenses[id] = SpectrumLicense({
            regulatoryRef: regulatoryRef, band: band, geographicRegion: region,
            bandwidthMHz: bandwidthMHz, licenseDurationYears: licenseDurationYears,
            reservePriceUSD: reserve, awardedPriceUSD: FHE.asEuint64(0),
            coverageObligationBps: coverage, awardedBidder: address(0), status: LicenseStatus.BidPhase
        });
        FHE.allowThis(licenses[id].reservePriceUSD);
        FHE.allowThis(licenses[id].awardedPriceUSD);
        FHE.allowThis(licenses[id].coverageObligationBps);
        emit LicenseCreated(id, band, region);
    }

    function submitBid(
        uint256 licenseId,
        externalEuint64 encBid, bytes calldata bidProof,
        externalEuint16 encFinancial, bytes calldata finProof,
        externalEuint16 encReadiness, bytes calldata readProof
    ) external returns (uint256 bidId) {
        require(isTelecomOperator[msg.sender], "Not telecom operator");
        require(licenses[licenseId].status == LicenseStatus.BidPhase, "Not in bid phase");
        euint64 bid = FHE.fromExternal(encBid, bidProof);
        euint16 financial = FHE.fromExternal(encFinancial, finProof);
        euint16 readiness = FHE.fromExternal(encReadiness, readProof);
        bidId = bidCount++;
        bids[bidId] = SpectrumBid({
            licenseId: licenseId, telecomOperator: msg.sender, bidAmountUSD: bid,
            financialQualScore: financial, networkReadinessScore: readiness, accepted: false
        });
        FHE.allowThis(bids[bidId].bidAmountUSD); FHE.allow(bids[bidId].bidAmountUSD, msg.sender);
        FHE.allowThis(bids[bidId].financialQualScore); FHE.allow(bids[bidId].financialQualScore, msg.sender);
        FHE.allowThis(bids[bidId].networkReadinessScore); FHE.allow(bids[bidId].networkReadinessScore, msg.sender);
        emit BidSubmitted(bidId, licenseId);
    }

    function awardLicense(uint256 licenseId, uint256 winningBidId) external onlyRegulator nonReentrant {
        SpectrumLicense storage lic = licenses[licenseId];
        SpectrumBid storage wb = bids[winningBidId];
        require(lic.status == LicenseStatus.BidPhase && wb.licenseId == licenseId, "Invalid");
        ebool reserveMet = FHE.ge(wb.bidAmountUSD, lic.reservePriceUSD);
        euint64 awarded = FHE.select(reserveMet, wb.bidAmountUSD, FHE.asEuint64(0));
        lic.awardedPriceUSD = awarded;
        lic.awardedBidder = wb.telecomOperator;
        lic.status = LicenseStatus.Awarded;
        wb.accepted = true;
        _totalAuctionRevenueUSD = FHE.add(_totalAuctionRevenueUSD, awarded);
        FHE.allowThis(lic.awardedPriceUSD); FHE.allow(lic.awardedPriceUSD, wb.telecomOperator);
        FHE.allowThis(_totalAuctionRevenueUSD);
        emit LicenseAwarded(licenseId, wb.telecomOperator);
    }

    function allowRevenueView(address viewer) external onlyOwner {
        FHE.allow(_totalAuctionRevenueUSD, viewer);
    }
}
