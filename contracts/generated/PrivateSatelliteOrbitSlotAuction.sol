// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSatelliteOrbitSlotAuction
/// @notice Geostationary orbit slot auction managed by ITU: encrypted bid prices,
///         encrypted interference budgets, and encrypted spectrum power limits.
contract PrivateSatelliteOrbitSlotAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum OrbitBand { GEO, MEO, LEO, VLEO, HEO }
    enum FrequencyBand { Lband, Sband, Cband, Kuband, Kaband, Qband, Vband }
    enum SlotStatus { Available, Reserved, Assigned, CoordinationPending, Expired }

    struct OrbitSlot {
        string slotId;
        OrbitBand orbitBand;
        FrequencyBand freqBand;
        int256 longitudeDeg;               // orbital longitude
        euint32 bandwidthMHz;              // encrypted bandwidth allocation
        euint32 powerLimitDBW;             // encrypted EIRP limit
        euint32 interferenceMarginDB;      // encrypted interference budget
        euint64 minimumBidUSD;             // encrypted minimum bid
        euint64 currentHighBidUSD;         // encrypted highest bid
        address highBidder;
        uint256 auctionEnd;
        SlotStatus status;
    }

    struct SpectrumBid {
        uint256 slotId;
        address operator;
        string satelliteName;
        euint64 bidAmountUSD;              // encrypted bid
        euint32 proposedPowerDBW;          // encrypted proposed EIRP
        euint32 coordinationBudgetDB;      // encrypted coordination budget
        bool disqualified;
    }

    mapping(uint256 => OrbitSlot) private slots;
    mapping(uint256 => SpectrumBid) private bids;
    mapping(uint256 => uint256[]) private slotBids;
    mapping(address => bool) public isITURegulator;
    mapping(address => bool) public isSatelliteOperator;

    uint256 public slotCount;
    uint256 public bidCount;
    euint64 private _totalSpectrumRevenue;

    event SlotRegistered(uint256 indexed id, string slotId, OrbitBand band, FrequencyBand freqBand);
    event BidPlaced(uint256 indexed bidId, uint256 slotId, address operator);
    event SlotAssigned(uint256 indexed id, address operator);

    modifier onlyITU() {
        require(isITURegulator[msg.sender] || msg.sender == owner(), "Not ITU regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSpectrumRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalSpectrumRevenue);
        isITURegulator[msg.sender] = true;
    }

    function addITU(address i) external onlyOwner { isITURegulator[i] = true; }
    function addOperator(address o) external onlyOwner { isSatelliteOperator[o] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerSlot(
        string calldata slotId, OrbitBand orbit, FrequencyBand freq, int256 longitude,
        externalEuint32 encBandwidth, bytes calldata bwProof,
        externalEuint32 encPowerLimit, bytes calldata plProof,
        externalEuint32 encInterference, bytes calldata intProof,
        externalEuint64 encMinBid, bytes calldata mbProof,
        uint256 auctionDays
    ) external onlyITU whenNotPaused returns (uint256 id) {
        euint32 bw = FHE.fromExternal(encBandwidth, bwProof);
        euint32 power = FHE.fromExternal(encPowerLimit, plProof);
        euint32 interference = FHE.fromExternal(encInterference, intProof);
        euint64 minBid = FHE.fromExternal(encMinBid, mbProof);
        id = slotCount++;
        slots[id] = OrbitSlot({
            slotId: slotId, orbitBand: orbit, freqBand: freq, longitudeDeg: longitude,
            bandwidthMHz: bw, powerLimitDBW: power, interferenceMarginDB: interference,
            minimumBidUSD: minBid, currentHighBidUSD: minBid,
            highBidder: address(0),
            auctionEnd: block.timestamp + auctionDays * 1 days,
            status: SlotStatus.Available
        });
        FHE.allowThis(slots[id].bandwidthMHz); FHE.allow(slots[id].bandwidthMHz, msg.sender);
        FHE.allowThis(slots[id].powerLimitDBW);
        FHE.allowThis(slots[id].interferenceMarginDB);
        FHE.allowThis(slots[id].minimumBidUSD);
        FHE.allowThis(slots[id].currentHighBidUSD);
        emit SlotRegistered(id, slotId, orbit, freq);
    }

    function placeBid(
        uint256 slotId, string calldata satelliteName,
        externalEuint64 encBid, bytes calldata bProof,
        externalEuint32 encProposedPower, bytes calldata ppProof,
        externalEuint32 encCoordBudget, bytes calldata cbProof
    ) external whenNotPaused nonReentrant returns (uint256 bidId) {
        require(isSatelliteOperator[msg.sender], "Not satellite operator");
        OrbitSlot storage s = slots[slotId];
        require(s.status == SlotStatus.Available && block.timestamp < s.auctionEnd, "Not available");
        euint64 bid = FHE.fromExternal(encBid, bProof);
        euint32 proposedPower = FHE.fromExternal(encProposedPower, ppProof);
        euint32 coordBudget = FHE.fromExternal(encCoordBudget, cbProof);
        // Must exceed minimum bid
        ebool aboveMin = FHE.ge(bid, s.minimumBidUSD);
        euint64 validBid = FHE.select(aboveMin, bid, FHE.asEuint64(0));
        // Update high bid
        ebool isHigher = FHE.gt(validBid, s.currentHighBidUSD);
        s.currentHighBidUSD = FHE.select(isHigher, validBid, s.currentHighBidUSD);
        s.highBidder = msg.sender;
        bidId = bidCount++;
        bids[bidId] = SpectrumBid({
            slotId: slotId, operator: msg.sender, satelliteName: satelliteName,
            bidAmountUSD: validBid, proposedPowerDBW: proposedPower,
            coordinationBudgetDB: coordBudget, disqualified: false
        });
        slotBids[slotId].push(bidId);
        FHE.allowThis(bids[bidId].bidAmountUSD); FHE.allow(bids[bidId].bidAmountUSD, msg.sender);
        FHE.allowThis(bids[bidId].proposedPowerDBW); FHE.allow(bids[bidId].proposedPowerDBW, msg.sender);
        FHE.allowThis(bids[bidId].coordinationBudgetDB);
        FHE.allowThis(s.currentHighBidUSD);
        emit BidPlaced(bidId, slotId, msg.sender);
    }

    function assignSlot(uint256 slotId) external onlyITU nonReentrant {
        OrbitSlot storage s = slots[slotId];
        require(s.status == SlotStatus.Available && block.timestamp >= s.auctionEnd, "Auction not ended");
        s.status = SlotStatus.Assigned;
        _totalSpectrumRevenue = FHE.add(_totalSpectrumRevenue, s.currentHighBidUSD);
        FHE.allow(s.currentHighBidUSD, s.highBidder);
        FHE.allowThis(_totalSpectrumRevenue);
        emit SlotAssigned(slotId, s.highBidder);
    }

    function disqualifyBid(uint256 bidId) external onlyITU { bids[bidId].disqualified = true; }

    function allowSpectrumStats(address viewer) external onlyOwner {
        FHE.allow(_totalSpectrumRevenue, viewer);
    }
}
