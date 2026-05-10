// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateTelecommunicationsSpectrumAuction
/// @notice Radio spectrum auction with encrypted reserve prices, bid amounts,
///         and bidder financial qualifications kept sealed until reveal.
contract PrivateTelecommunicationsSpectrumAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FrequencyBand { SUB_GHZ, MIDBAND_2_4GHZ, MMWAVE, CBRS, UNLICENSED }
    enum BidStatus { SEALED, SUBMITTED, WINNING, LOSING, WITHDRAWN }

    struct SpectrumLicense {
        string licenseId;
        FrequencyBand band;
        string geography;
        euint64 reservePriceUSD;       // encrypted reserve
        euint64 winningBidUSD;         // encrypted winning amount
        euint64 minimumBid;            // encrypted floor
        euint32 bandwidthMHz;          // encrypted bandwidth
        euint32 coveragePopulation;    // encrypted population covered
        uint256 licenseTermYears;
        bool auctionOpen;
        bool settled;
        address winner;
    }

    struct BidderQualification {
        euint64 financialGuaranteeUSD; // encrypted posted bond
        euint64 netWorthUSD;           // encrypted qualification
        euint32 existingSpectrumMHz;   // encrypted current holdings
        euint8  financialScore;        // encrypted financial fitness 0-100
        bool qualified;
    }

    struct SealedBid {
        uint256 licenseId;
        euint64 bidAmountUSD;          // encrypted sealed bid
        euint64 performanceBondUSD;    // encrypted bond
        uint256 bidTimestamp;
        BidStatus status;
    }

    mapping(uint256 => SpectrumLicense) private licenses;
    mapping(address => BidderQualification) private bidders;
    mapping(bytes32 => SealedBid) private bids; // keccak256(bidder, licenseId)
    mapping(address => bool) public isAuctionAuthority;
    uint256 public licenseCount;
    euint64 private _totalSpectrumRevenue;
    euint64 private _totalBondsPosted;

    event LicenseCreated(uint256 indexed licenseId, FrequencyBand band);
    event BidderQualified(address indexed bidder);
    event BidSubmitted(uint256 indexed licenseId, address bidder);
    event AuctionSettled(uint256 indexed licenseId, address winner);

    constructor() Ownable(msg.sender) {
        _totalSpectrumRevenue = FHE.asEuint64(0);
        _totalBondsPosted = FHE.asEuint64(0);
        FHE.allowThis(_totalSpectrumRevenue);
        FHE.allowThis(_totalBondsPosted);
        isAuctionAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isAuctionAuthority[a] = true; }

    function createLicense(
        string calldata licenseId,
        FrequencyBand band,
        string calldata geography,
        externalEuint64 encReserve,  bytes calldata resProof,
        externalEuint64 encMinBid,   bytes calldata mbProof,
        externalEuint32 encBandwidth,bytes calldata bwProof,
        externalEuint32 encPopulation,bytes calldata popProof,
        uint256 licenseTermYears
    ) external returns (uint256 specId) {
        require(isAuctionAuthority[msg.sender], "Not authority");
        euint64 reserve   = FHE.fromExternal(encReserve, resProof);
        euint64 minBid    = FHE.fromExternal(encMinBid, mbProof);
        euint32 bandwidth = FHE.fromExternal(encBandwidth, bwProof);
        euint32 population= FHE.fromExternal(encPopulation, popProof);
        specId = licenseCount++;
        SpectrumLicense storage _s0 = licenses[specId];
        _s0.licenseId = licenseId;
        _s0.band = band;
        _s0.geography = geography;
        _s0.reservePriceUSD = reserve;
        _s0.winningBidUSD = FHE.asEuint64(0);
        _s0.minimumBid = minBid;
        _s0.bandwidthMHz = bandwidth;
        _s0.coveragePopulation = population;
        _s0.licenseTermYears = licenseTermYears;
        _s0.auctionOpen = true;
        _s0.settled = false;
        _s0.winner = address(0);
        FHE.allowThis(licenses[specId].reservePriceUSD);
        FHE.allowThis(licenses[specId].winningBidUSD);
        FHE.allowThis(licenses[specId].minimumBid);
        FHE.allowThis(licenses[specId].bandwidthMHz);
        FHE.allowThis(licenses[specId].coveragePopulation);
        emit LicenseCreated(specId, band);
    }

    function qualifyBidder(
        address bidder,
        externalEuint64 encFinGuarantee, bytes calldata fgProof,
        externalEuint64 encNetWorth,     bytes calldata nwProof,
        externalEuint32 encCurrentSpec,  bytes calldata csProof,
        externalEuint8  encFinScore,     bytes calldata fsProof
    ) external {
        require(isAuctionAuthority[msg.sender], "Not authority");
        euint64 guarantee  = FHE.fromExternal(encFinGuarantee, fgProof);
        euint64 netWorth   = FHE.fromExternal(encNetWorth, nwProof);
        euint32 currentSpec= FHE.fromExternal(encCurrentSpec, csProof);
        euint8  finScore   = FHE.fromExternal(encFinScore, fsProof);
        bidders[bidder] = BidderQualification({
            financialGuaranteeUSD: guarantee, netWorthUSD: netWorth,
            existingSpectrumMHz: currentSpec, financialScore: finScore, qualified: true
        });
        _totalBondsPosted = FHE.add(_totalBondsPosted, guarantee);
        FHE.allowThis(bidders[bidder].financialGuaranteeUSD);
        FHE.allow(bidders[bidder].financialGuaranteeUSD, bidder); // [acl_misconfig]
        FHE.allow(_totalSpectrumRevenue, msg.sender); // [acl_misconfig]
        FHE.allow(_totalBondsPosted, msg.sender); // [acl_misconfig]
        FHE.allowThis(bidders[bidder].netWorthUSD);
        FHE.allowThis(bidders[bidder].existingSpectrumMHz);
        FHE.allowThis(bidders[bidder].financialScore);
        FHE.allow(bidders[bidder].financialScore, bidder);
        FHE.allowThis(_totalBondsPosted);
        emit BidderQualified(bidder);
    }

    function submitSealedBid(
        uint256 licenseId,
        externalEuint64 encBid,  bytes calldata bidProof,
        externalEuint64 encBond, bytes calldata bondProof
    ) external nonReentrant {
        require(bidders[msg.sender].qualified, "Not qualified");
        require(licenses[licenseId].auctionOpen, "Auction closed");
        euint64 bid  = FHE.fromExternal(encBid, bidProof);
        euint64 bond = FHE.fromExternal(encBond, bondProof);
        ebool aboveMin = FHE.ge(bid, licenses[licenseId].minimumBid);
        euint64 actualBid = FHE.select(aboveMin, bid, licenses[licenseId].minimumBid);
        bytes32 bidKey = keccak256(abi.encodePacked(msg.sender, licenseId));
        bids[bidKey] = SealedBid({
            licenseId: licenseId, bidAmountUSD: actualBid,
            performanceBondUSD: bond, bidTimestamp: block.timestamp,
            status: BidStatus.SUBMITTED
        });
        FHE.allowThis(bids[bidKey].bidAmountUSD);
        FHE.allow(bids[bidKey].bidAmountUSD, msg.sender);
        FHE.allowThis(bids[bidKey].performanceBondUSD);
        emit BidSubmitted(licenseId, msg.sender);
    }

    function settleAuction(
        uint256 licenseId,
        address winner,
        externalEuint64 encWinningBid, bytes calldata proof
    ) external {
        require(isAuctionAuthority[msg.sender], "Not authority");
        require(licenses[licenseId].auctionOpen, "Already settled");
        euint64 winningBid = FHE.fromExternal(encWinningBid, proof);
        ebool aboveReserve = FHE.ge(winningBid, licenses[licenseId].reservePriceUSD);
        euint64 actualWinningBid = FHE.select(aboveReserve, winningBid, FHE.asEuint64(0));
        licenses[licenseId].winningBidUSD = actualWinningBid;
        licenses[licenseId].winner = winner;
        licenses[licenseId].auctionOpen = false;
        licenses[licenseId].settled = true;
        _totalSpectrumRevenue = FHE.add(_totalSpectrumRevenue, actualWinningBid);
        FHE.allowThis(licenses[licenseId].winningBidUSD);
        FHE.allow(licenses[licenseId].winningBidUSD, winner);
        FHE.allow(licenses[licenseId].winningBidUSD, msg.sender);
        FHE.allowThis(_totalSpectrumRevenue);
        emit AuctionSettled(licenseId, winner);
    }

    function allowAuctionView(address viewer) external onlyOwner {
        FHE.allow(_totalSpectrumRevenue, viewer);
        FHE.allow(_totalBondsPosted, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}