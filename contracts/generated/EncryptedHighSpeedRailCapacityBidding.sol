// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedHighSpeedRailCapacityBidding
/// @notice Train slot capacity marketplace where transport operators bid for
///         peak-hour rail slots. Competitor bid amounts and capacity needs
///         remain encrypted to prevent anti-competitive collusion.
contract EncryptedHighSpeedRailCapacityBidding is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct RailSlot {
        euint64 reservePrice;       // minimum acceptable price
        euint64 highestBid;         // current winning bid
        address currentWinner;
        euint32 capacityUnits;      // encrypted capacity (trains per hour)
        euint32 peakDemandScore;    // oracle-provided demand score
        string routeCode;
        bool active;
        uint256 auctionEnd;
        uint256 slotDate;
    }

    struct OperatorBid {
        euint64 bidAmount;
        euint32 demandForecast;     // operator's private demand estimate
        euint32 revenueProjection;  // encrypted projected revenue
        bool active;
    }

    mapping(uint256 => RailSlot) private slots;
    mapping(uint256 => mapping(address => OperatorBid)) private bids;
    mapping(address => bool) public licensedOperators;
    mapping(address => euint64) private operatorDeposits;
    uint256 public slotCount;

    euint64 private _totalRevenue;
    euint64 private _depositPool;

    event SlotCreated(uint256 indexed slotId, string routeCode);
    event BidPlaced(uint256 indexed slotId, address indexed operator);
    event SlotAwarded(uint256 indexed slotId, address indexed winner);
    event DepositRefunded(uint256 indexed slotId, address indexed operator);

    constructor() Ownable(msg.sender) {
        _totalRevenue = FHE.asEuint64(0);
        _depositPool = FHE.asEuint64(0);
        FHE.allowThis(_totalRevenue);
        FHE.allowThis(_depositPool);
    }

    function licenseOperator(address operator) external onlyOwner {
        licensedOperators[operator] = true;
    }

    function createSlot(
        externalEuint64 encReserve, bytes calldata reserveProof,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint32 encDemand, bytes calldata demandProof,
        string calldata routeCode,
        uint256 durationHours,
        uint256 slotDate
    ) external onlyOwner returns (uint256 slotId) {
        slotId = slotCount++;
        RailSlot storage s = slots[slotId];
        s.reservePrice = FHE.fromExternal(encReserve, reserveProof);
        s.capacityUnits = FHE.fromExternal(encCapacity, capProof);
        s.peakDemandScore = FHE.fromExternal(encDemand, demandProof);
        s.highestBid = FHE.asEuint64(0);
        s.routeCode = routeCode;
        s.active = true;
        s.auctionEnd = block.timestamp + (durationHours * 1 hours);
        s.slotDate = slotDate;
        FHE.allowThis(s.reservePrice);
        FHE.allowThis(s.capacityUnits);
        FHE.allowThis(s.peakDemandScore);
        FHE.allowThis(s.highestBid);
        emit SlotCreated(slotId, routeCode);
    }

    function depositBond(
        externalEuint64 encAmount, bytes calldata proof
    ) external {
        require(licensedOperators[msg.sender], "Not licensed");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        if (operatorDeposits[msg.sender].eq(FHE.asEuint64(0)) == FHE.eq(FHE.asEuint64(0), FHE.asEuint64(0))) {
            operatorDeposits[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(operatorDeposits[msg.sender]);
        }
        operatorDeposits[msg.sender] = FHE.add(operatorDeposits[msg.sender], amount);
        _depositPool = FHE.add(_depositPool, amount);
        FHE.allowThis(operatorDeposits[msg.sender]);
        FHE.allow(operatorDeposits[msg.sender], msg.sender);
        FHE.allowThis(_depositPool);
    }

    function placeBid(
        uint256 slotId,
        externalEuint64 encBid, bytes calldata bidProof,
        externalEuint32 encForecast, bytes calldata forecastProof,
        externalEuint32 encRevenue, bytes calldata revProof
    ) external nonReentrant {
        require(licensedOperators[msg.sender], "Not licensed");
        RailSlot storage s = slots[slotId];
        require(s.active && block.timestamp < s.auctionEnd, "Auction closed");
        euint64 bid = FHE.fromExternal(encBid, bidProof);
        // Check bid covers deposit bond requirement
        ebool hasBond = FHE.ge(operatorDeposits[msg.sender], bid);
        euint64 actualBid = FHE.select(hasBond, bid, FHE.asEuint64(0));
        ebool isHigher = FHE.gt(actualBid, s.highestBid);
        s.highestBid = FHE.select(isHigher, actualBid, s.highestBid);
        bids[slotId][msg.sender].bidAmount = actualBid;
        bids[slotId][msg.sender].demandForecast = FHE.fromExternal(encForecast, forecastProof);
        bids[slotId][msg.sender].revenueProjection = FHE.fromExternal(encRevenue, revProof);
        bids[slotId][msg.sender].active = true;
        FHE.allowThis(s.highestBid);
        FHE.allow(s.highestBid, owner());
        FHE.allowThis(bids[slotId][msg.sender].bidAmount);
        FHE.allow(bids[slotId][msg.sender].bidAmount, msg.sender);
        FHE.allowThis(bids[slotId][msg.sender].demandForecast);
        FHE.allowThis(bids[slotId][msg.sender].revenueProjection);
        FHE.allow(isHigher, msg.sender);
        emit BidPlaced(slotId, msg.sender);
    }

    function awardSlot(uint256 slotId, address winner) external onlyOwner nonReentrant {
        RailSlot storage s = slots[slotId];
        require(s.active, "Not active");
        require(block.timestamp >= s.auctionEnd, "Still running");
        ebool reserveMet = FHE.ge(s.highestBid, s.reservePrice);
        euint64 payment = FHE.select(reserveMet, s.highestBid, FHE.asEuint64(0));
        s.currentWinner = winner;
        s.active = false;
        _totalRevenue = FHE.add(_totalRevenue, payment);
        FHE.allowThis(_totalRevenue);
        FHE.allow(payment, owner());
        FHE.allow(reserveMet, winner);
        FHE.allow(s.capacityUnits, winner);
        emit SlotAwarded(slotId, winner);
    }

    function allowMyBid(uint256 slotId, address viewer) external {
        FHE.allow(bids[slotId][msg.sender].bidAmount, viewer);
    }

    function allowMarketMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalRevenue, viewer);
        FHE.allow(_depositPool, viewer);
    }
}
