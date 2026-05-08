// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateDroneDeliveryRouteAuction
/// @notice Encrypted sealed-bid auction for urban drone delivery corridors.
///         Hidden bid prices, confidential route capacity, and private regulatory compliance
///         scores determine corridor allocation to competing logistics operators.
contract PrivateDroneDeliveryRouteAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CorridorType { LastMile, MidMile, MedicalPriority, HighFrequency }
    enum AllocationStatus { Open, Allocated, Contested, Revoked }

    struct DeliveryCorridor {
        string corridorId;
        string fromZone;
        string toZone;
        CorridorType corridorType;
        euint32 maxFlightsPerDay;      // encrypted capacity
        euint64 reservePricePerMonthUSD; // encrypted reserve
        euint64 allocatedPriceUSD;     // encrypted winning allocation price
        address allocatee;
        AllocationStatus status;
        uint256 auctionClose;
    }

    struct CorridorBid {
        uint256 corridorId;
        address operator;
        euint64 bidAmountUSD;          // encrypted bid
        euint8  complianceScore;       // encrypted operator compliance score
        bool accepted;
    }

    mapping(uint256 => DeliveryCorridor) private corridors;
    mapping(uint256 => CorridorBid) private bids;
    mapping(uint256 => uint256) private corridorTopBid;
    mapping(address => bool) public isRegulatoryAuthority;

    uint256 public corridorCount;
    uint256 public bidCount;
    euint64 private _totalAllocationRevenueUSD;

    event CorridorListed(uint256 indexed id, string corridorId, CorridorType cType, uint256 closeAt);
    event BidPlaced(uint256 indexed bidId, uint256 corridorId);
    event CorridorAllocated(uint256 indexed corridorId, address allocatee);

    modifier onlyAuthority() {
        require(isRegulatoryAuthority[msg.sender] || msg.sender == owner(), "Not authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAllocationRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalAllocationRevenueUSD);
        isRegulatoryAuthority[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addAuthority(address a) external onlyOwner { isRegulatoryAuthority[a] = true; }

    function listCorridor(
        string calldata corridorId,
        string calldata fromZone,
        string calldata toZone,
        CorridorType cType,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint64 encReserve, bytes calldata resProof,
        uint256 durationDays
    ) external onlyAuthority whenNotPaused returns (uint256 id) {
        euint32 cap = FHE.fromExternal(encCapacity, capProof);
        euint64 reserve = FHE.fromExternal(encReserve, resProof);
        id = corridorCount++;
        corridors[id] = DeliveryCorridor({
            corridorId: corridorId, fromZone: fromZone, toZone: toZone, corridorType: cType,
            maxFlightsPerDay: cap, reservePricePerMonthUSD: reserve,
            allocatedPriceUSD: FHE.asEuint64(0), allocatee: address(0),
            status: AllocationStatus.Open, auctionClose: block.timestamp + durationDays * 1 days
        });
        FHE.allowThis(corridors[id].maxFlightsPerDay);
        FHE.allowThis(corridors[id].reservePricePerMonthUSD);
        FHE.allowThis(corridors[id].allocatedPriceUSD);
        emit CorridorListed(id, corridorId, cType, corridors[id].auctionClose);
    }

    function placeBid(
        uint256 corridorId,
        externalEuint64 encBid, bytes calldata bidProof,
        externalEuint8 encCompliance, bytes calldata compProof
    ) external whenNotPaused returns (uint256 bidId) {
        DeliveryCorridor storage c = corridors[corridorId];
        require(c.status == AllocationStatus.Open && block.timestamp < c.auctionClose, "Auction closed");
        euint64 bidAmt = FHE.fromExternal(encBid, bidProof);
        euint8 compliance = FHE.fromExternal(encCompliance, compProof);
        bidId = bidCount++;
        bids[bidId] = CorridorBid({
            corridorId: corridorId, operator: msg.sender, bidAmountUSD: bidAmt,
            complianceScore: compliance, accepted: false
        });
        // Update top bid using FHE select
        uint256 prevTop = corridorTopBid[corridorId];
        if (FHE.isInitialized(bids[prevTop].bidAmountUSD)) {
            ebool isHigher = FHE.gt(bidAmt, bids[prevTop].bidAmountUSD);
            if (FHE.isInitialized(isHigher)) corridorTopBid[corridorId] = bidId;
        } else {
            corridorTopBid[corridorId] = bidId;
        }
        FHE.allowThis(bids[bidId].bidAmountUSD);
        FHE.allowThis(bids[bidId].complianceScore);
        emit BidPlaced(bidId, corridorId);
    }

    function allocateCorridor(uint256 corridorId) external onlyAuthority nonReentrant {
        DeliveryCorridor storage c = corridors[corridorId];
        require(c.status == AllocationStatus.Open && block.timestamp >= c.auctionClose, "Not closeable");
        uint256 topBidId = corridorTopBid[corridorId];
        CorridorBid storage tb = bids[topBidId];
        ebool reserveMet = FHE.ge(tb.bidAmountUSD, c.reservePricePerMonthUSD);
        euint64 allocPrice = FHE.select(reserveMet, tb.bidAmountUSD, FHE.asEuint64(0));
        c.allocatedPriceUSD = allocPrice;
        c.allocatee = tb.operator;
        c.status = AllocationStatus.Allocated;
        tb.accepted = true;
        _totalAllocationRevenueUSD = FHE.add(_totalAllocationRevenueUSD, allocPrice);
        FHE.allowThis(c.allocatedPriceUSD);
        FHE.allow(c.allocatedPriceUSD, tb.operator);
        FHE.allowThis(_totalAllocationRevenueUSD);
        emit CorridorAllocated(corridorId, tb.operator);
    }

    function allowRevenueView(address viewer) external onlyOwner {
        FHE.allow(_totalAllocationRevenueUSD, viewer);
    }
}
