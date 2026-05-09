// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateOlympicSponsorshipAuction
/// @notice Olympic committee auction: brands bid encrypted sponsorship amounts per
///         category (apparel, beverages, tech), sealed-bid, exclusive category awards.
contract PrivateOlympicSponsorshipAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SponsorCategory { Apparel, Beverages, Technology, Automotive, Finance, Telecom, Media }
    enum AuctionStatus { Open, Closed, Awarded, Cancelled }

    struct SponsorshipLot {
        SponsorCategory category;
        string lotDescription;
        string exclusivityTerm;        // e.g. "4 years exclusive"
        euint64 reservePriceUSD;       // encrypted minimum acceptable bid
        euint64 winningBidUSD;         // encrypted winning amount
        euint64 totalBidVolume;        // encrypted sum of all bids
        uint256 auctionDeadline;
        AuctionStatus status;
        address winner;
    }

    struct SponsorBid {
        euint64 bidAmountUSD;          // encrypted bid value
        euint64 activationBudgetUSD;   // encrypted activation spending
        euint8  reputationScore;       // encrypted brand reputation score
        bool submitted;
        bool qualified;
    }

    mapping(uint256 => SponsorshipLot) private lots;
    mapping(uint256 => mapping(address => SponsorBid)) private bids;
    mapping(address => bool) public isOlympicCommittee;
    mapping(address => bool) public isQualifiedBrand;
    uint256 public lotCount;
    euint64 private _totalSponsorshipRevenue;
    euint8  private _minReputationScore;

    event LotCreated(uint256 indexed id, SponsorCategory category);
    event BidSubmitted(uint256 indexed lotId, address brand);
    event LotAwarded(uint256 indexed lotId, address winner);
    event LotCancelled(uint256 indexed lotId);

    modifier onlyCommittee() {
        require(isOlympicCommittee[msg.sender] || msg.sender == owner(), "Not committee");
        _;
    }

    constructor(externalEuint8 encMinRep, bytes memory proof) Ownable(msg.sender) {
        _minReputationScore = FHE.fromExternal(encMinRep, proof);
        _totalSponsorshipRevenue = FHE.asEuint64(0);
        FHE.allowThis(_minReputationScore);
        FHE.allowThis(_totalSponsorshipRevenue);
        isOlympicCommittee[msg.sender] = true;
    }

    function addCommitteeMember(address c) external onlyOwner { isOlympicCommittee[c] = true; }
    function qualifyBrand(address b) external onlyCommittee { isQualifiedBrand[b] = true; }

    function createLot(
        SponsorCategory category, string calldata description, string calldata term,
        externalEuint64 encReserve, bytes calldata proof,
        uint256 deadlineDays
    ) external onlyCommittee returns (uint256 id) {
        euint64 reserve = FHE.fromExternal(encReserve, proof);
        id = lotCount++;
        lots[id].category = category;
        lots[id].lotDescription = description;
        lots[id].exclusivityTerm = term;
        lots[id].reservePriceUSD = reserve;
        lots[id].winningBidUSD = FHE.asEuint64(0);
        lots[id].totalBidVolume = FHE.asEuint64(0);
        lots[id].auctionDeadline = block.timestamp + deadlineDays * 1 days;
        lots[id].status = AuctionStatus.Open;
        lots[id].winner = address(0);
        FHE.allowThis(lots[id].reservePriceUSD);
        FHE.allowThis(lots[id].winningBidUSD);
        FHE.allowThis(lots[id].totalBidVolume);
        emit LotCreated(id, category);
    }

    function submitBid(
        uint256 lotId,
        externalEuint64 encBid, bytes calldata bidPf,
        externalEuint64 encActivation, bytes calldata actPf,
        externalEuint8 encReputation, bytes calldata repPf
    ) external nonReentrant {
        require(isQualifiedBrand[msg.sender], "Not qualified brand");
        SponsorshipLot storage lot = lots[lotId];
        require(lot.status == AuctionStatus.Open && block.timestamp < lot.auctionDeadline, "Closed");
        euint64 bid = FHE.fromExternal(encBid, bidPf);
        euint64 activation = FHE.fromExternal(encActivation, actPf);
        euint8 reputation = FHE.fromExternal(encReputation, repPf);
        // Qualify bid based on reputation score
        ebool reputationOk = FHE.ge(reputation, _minReputationScore);
        ebool aboveReserve = FHE.ge(bid, lot.reservePriceUSD);
        bids[lotId][msg.sender] = SponsorBid({
            bidAmountUSD: bid, activationBudgetUSD: activation,
            reputationScore: reputation, submitted: true,
            qualified: FHE.isInitialized(reputationOk) && FHE.isInitialized(aboveReserve)
        });
        lot.totalBidVolume = FHE.add(lot.totalBidVolume, bid);
        // Track best bid
        ebool isBest = FHE.gt(bid, lot.winningBidUSD);
        if (FHE.isInitialized(isBest) && bids[lotId][msg.sender].qualified) {
            lot.winningBidUSD = bid;
            lot.winner = msg.sender;
            FHE.allowThis(lot.winningBidUSD);
        }
        FHE.allowThis(bids[lotId][msg.sender].bidAmountUSD);
        FHE.allow(bids[lotId][msg.sender].bidAmountUSD, msg.sender);
        FHE.allowThis(bids[lotId][msg.sender].activationBudgetUSD);
        FHE.allowThis(bids[lotId][msg.sender].reputationScore);
        FHE.allowThis(lot.totalBidVolume);
        emit BidSubmitted(lotId, msg.sender);
    }

    function closeLot(uint256 lotId) external onlyCommittee {
        lots[lotId].status = AuctionStatus.Closed;
    }

    function awardLot(uint256 lotId, address winner) external onlyCommittee {
        SponsorshipLot storage lot = lots[lotId];
        require(lot.status == AuctionStatus.Closed, "Not closed");
        require(bids[lotId][winner].submitted && bids[lotId][winner].qualified, "Invalid winner");
        lot.winner = winner;
        lot.winningBidUSD = bids[lotId][winner].bidAmountUSD;
        lot.status = AuctionStatus.Awarded;
        _totalSponsorshipRevenue = FHE.add(_totalSponsorshipRevenue, lot.winningBidUSD);
        FHE.allowThis(lot.winningBidUSD);
        FHE.allow(lot.winningBidUSD, winner);
        FHE.allowThis(_totalSponsorshipRevenue);
        emit LotAwarded(lotId, winner);
    }

    function cancelLot(uint256 lotId) external onlyCommittee {
        lots[lotId].status = AuctionStatus.Cancelled;
        emit LotCancelled(lotId);
    }

    function allowLotDetails(uint256 lotId, address viewer) external onlyCommittee {
        FHE.allow(lots[lotId].reservePriceUSD, viewer);
        FHE.allow(lots[lotId].winningBidUSD, viewer);
        FHE.allow(lots[lotId].totalBidVolume, viewer);
    }

    function allowRevenueStats(address viewer) external onlyOwner {
        FHE.allow(_totalSponsorshipRevenue, viewer);
    }
}
