// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAirportLandingSlotAuction
/// @notice Encrypted landing slot auction for congested airports: hidden bid prices, confidential
///         airline financial capacity, private slot pair trading, and encrypted performance
///         scores affecting slot retention rights.
contract PrivateAirportLandingSlotAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SlotType { Peak, OffPeak, NightSlot, CoordinatedHub }
    enum SlotStatus { Available, Bid, Awarded, Trading }

    struct LandingSlot {
        string airportCode;
        SlotType slotType;
        uint256 scheduledTime;
        euint64 reservePriceUSD;       // encrypted reserve
        euint64 awardedPriceUSD;       // encrypted winning bid
        address awardedAirline;
        SlotStatus status;
    }

    struct SlotBid {
        uint256 slotId;
        address airline;
        euint64 bidAmountUSD;          // encrypted bid
        euint16 fleetUtilizationBps;   // encrypted utilization score
        bool accepted;
    }

    mapping(uint256 => LandingSlot) private slots;
    mapping(uint256 => SlotBid) private bids;
    mapping(uint256 => uint256) private slotHighBid;
    mapping(address => bool) public isAirportAuthority;

    uint256 public slotCount;
    uint256 public bidCount;
    euint64 private _totalSlotRevenueUSD;

    event SlotCreated(uint256 indexed id, string airportCode, SlotType slotType);
    event SlotBidPlaced(uint256 indexed bidId, uint256 slotId);
    event SlotAwarded(uint256 indexed slotId, address airline);

    modifier onlyAirportAuthority() {
        require(isAirportAuthority[msg.sender] || msg.sender == owner(), "Not airport authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSlotRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSlotRevenueUSD);
        isAirportAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isAirportAuthority[a] = true; }

    function createSlot(
        string calldata airportCode, SlotType slotType, uint256 scheduledTime,
        externalEuint64 encReserve, bytes calldata proof
    ) external onlyAirportAuthority returns (uint256 id) {
        euint64 reserve = FHE.fromExternal(encReserve, proof);
        id = slotCount++;
        slots[id] = LandingSlot({
            airportCode: airportCode, slotType: slotType, scheduledTime: scheduledTime,
            reservePriceUSD: reserve, awardedPriceUSD: FHE.asEuint64(0),
            awardedAirline: address(0), status: SlotStatus.Available
        });
        FHE.allowThis(slots[id].reservePriceUSD);
        FHE.allowThis(slots[id].awardedPriceUSD);
        emit SlotCreated(id, airportCode, slotType);
    }

    function placeBid(
        uint256 slotId,
        externalEuint64 encBid, bytes calldata bidProof,
        externalEuint16 encUtilization, bytes calldata utilProof
    ) external returns (uint256 bidId) {
        require(slots[slotId].status == SlotStatus.Available || slots[slotId].status == SlotStatus.Bid, "Not biddable");
        euint64 bid = FHE.fromExternal(encBid, bidProof);
        euint16 utilization = FHE.fromExternal(encUtilization, utilProof);
        bidId = bidCount++;
        bids[bidId] = SlotBid({ slotId: slotId, airline: msg.sender, bidAmountUSD: bid, fleetUtilizationBps: utilization, accepted: false });
        if (FHE.isInitialized(bids[slotHighBid[slotId]].bidAmountUSD)) {
            ebool isHigher = FHE.gt(bid, bids[slotHighBid[slotId]].bidAmountUSD);
            if (FHE.isInitialized(isHigher)) slotHighBid[slotId] = bidId;
        } else {
            slotHighBid[slotId] = bidId;
        }
        slots[slotId].status = SlotStatus.Bid;
        FHE.allowThis(bids[bidId].bidAmountUSD); FHE.allow(bids[bidId].bidAmountUSD, msg.sender);
        FHE.allowThis(bids[bidId].fleetUtilizationBps);
        emit SlotBidPlaced(bidId, slotId);
    }

    function awardSlot(uint256 slotId) external onlyAirportAuthority nonReentrant {
        LandingSlot storage s = slots[slotId];
        require(s.status == SlotStatus.Bid, "No bids");
        uint256 highBidId = slotHighBid[slotId];
        SlotBid storage hb = bids[highBidId];
        ebool reserveMet = FHE.ge(hb.bidAmountUSD, s.reservePriceUSD);
        euint64 awardedPrice = FHE.select(reserveMet, hb.bidAmountUSD, FHE.asEuint64(0));
        s.awardedPriceUSD = awardedPrice;
        s.awardedAirline = hb.airline;
        s.status = SlotStatus.Awarded;
        hb.accepted = true;
        _totalSlotRevenueUSD = FHE.add(_totalSlotRevenueUSD, awardedPrice);
        FHE.allowThis(s.awardedPriceUSD); FHE.allow(s.awardedPriceUSD, hb.airline);
        FHE.allowThis(_totalSlotRevenueUSD);
        emit SlotAwarded(slotId, hb.airline);
    }

    function allowRevenueView(address viewer) external onlyOwner {
        FHE.allow(_totalSlotRevenueUSD, viewer);
    }
}
