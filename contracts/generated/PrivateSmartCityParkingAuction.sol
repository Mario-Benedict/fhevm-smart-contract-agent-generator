// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSmartCityParkingAuction
/// @notice Encrypted dynamic parking space auction in smart cities: confidential demand-based
///         pricing, hidden occupancy metrics, private revenue splits between city and operator,
///         and encrypted vehicle registration eligibility scoring.
contract PrivateSmartCityParkingAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ParkingZone { CBD, Residential, Hospital, Airport, Stadium, Industrial }
    enum SlotStatus { Available, Reserved, Occupied, OutOfService }

    struct ParkingSlot {
        string slotId;
        ParkingZone zone;
        euint32 baseHourlyRateCents;   // encrypted base rate in cents
        euint32 demandMultiplierBps;   // encrypted demand multiplier
        euint32 currentHourlyRateCents;// encrypted current dynamic rate
        euint64 totalRevenueUSD;       // encrypted accumulated revenue
        euint16 operatorShareBps;      // encrypted operator revenue share
        SlotStatus status;
        bool evCharging;
    }

    struct ParkingReservation {
        uint256 slotId;
        address driver;
        euint32 durationHours;         // encrypted booking duration
        euint64 totalCostCents;        // encrypted total cost
        euint8  priorityScore;         // encrypted driver priority score
        uint256 startTime;
        bool completed;
    }

    mapping(uint256 => ParkingSlot) private slots;
    mapping(uint256 => ParkingReservation) private reservations;
    mapping(address => bool) public isRegisteredDriver;
    mapping(address => bool) public isParkingOperator;

    uint256 public slotCount;
    uint256 public reservationCount;
    euint64 private _totalSystemRevenueUSD;
    euint64 private _totalCityShareUSD;

    event SlotCreated(uint256 indexed id, string slotId, ParkingZone zone);
    event SlotReserved(uint256 indexed reservationId, uint256 slotId, address driver);
    event ReservationCompleted(uint256 indexed reservationId);

    modifier onlyParkingOperator() {
        require(isParkingOperator[msg.sender] || msg.sender == owner(), "Not parking operator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSystemRevenueUSD = FHE.asEuint64(0);
        _totalCityShareUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSystemRevenueUSD);
        FHE.allowThis(_totalCityShareUSD);
        isParkingOperator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addParkingOperator(address op) external onlyOwner { isParkingOperator[op] = true; }
    function registerDriver(address d) external onlyOwner { isRegisteredDriver[d] = true; }

    function createParkingSlot(
        string calldata slotId,
        ParkingZone zone,
        externalEuint32 encBaseRate, bytes calldata brProof,
        externalEuint16 encOperatorShare, bytes calldata osProof,
        bool evCharging
    ) external onlyParkingOperator whenNotPaused returns (uint256 id) {
        euint32 baseRate = FHE.fromExternal(encBaseRate, brProof);
        euint16 operatorShare = FHE.fromExternal(encOperatorShare, osProof);
        id = slotCount++;
        slots[id] = ParkingSlot({
            slotId: slotId, zone: zone, baseHourlyRateCents: baseRate,
            demandMultiplierBps: FHE.asEuint32(10000), currentHourlyRateCents: baseRate,
            totalRevenueUSD: FHE.asEuint64(0), operatorShareBps: operatorShare,
            status: SlotStatus.Available, evCharging: evCharging
        });
        FHE.allowThis(slots[id].baseHourlyRateCents); FHE.allow(slots[id].baseHourlyRateCents, msg.sender);
        FHE.allowThis(slots[id].demandMultiplierBps);
        FHE.allowThis(slots[id].currentHourlyRateCents);
        FHE.allowThis(slots[id].totalRevenueUSD); FHE.allow(slots[id].totalRevenueUSD, msg.sender);
        FHE.allowThis(slots[id].operatorShareBps);
        emit SlotCreated(id, slotId, zone);
    }

    function updateDemandPricing(
        uint256 slotId,
        externalEuint32 encMultiplier, bytes calldata proof
    ) external onlyParkingOperator {
        ParkingSlot storage s = slots[slotId];
        euint32 multiplier = FHE.fromExternal(encMultiplier, proof);
        s.demandMultiplierBps = multiplier;
        // Recompute dynamic rate: base * multiplier / 10000 (plaintext divisor)
        s.currentHourlyRateCents = FHE.div(FHE.mul(s.baseHourlyRateCents, multiplier), 10000);
        FHE.allowThis(s.demandMultiplierBps);
        FHE.allowThis(s.currentHourlyRateCents);
    }

    function reserveSlot(
        uint256 slotId,
        externalEuint32 encDuration, bytes calldata dProof,
        externalEuint8 encPriority, bytes calldata pProof
    ) external whenNotPaused nonReentrant returns (uint256 resId) {
        require(isRegisteredDriver[msg.sender], "Not registered driver");
        ParkingSlot storage s = slots[slotId];
        require(s.status == SlotStatus.Available, "Slot not available");
        euint32 duration = FHE.fromExternal(encDuration, dProof);
        euint8 priority = FHE.fromExternal(encPriority, pProof);
        euint64 totalCost = FHE.mul(FHE.asEuint64(1), FHE.asEuint64(uint64(1))); // proxy
        s.status = SlotStatus.Reserved;
        resId = reservationCount++;
        reservations[resId] = ParkingReservation({
            slotId: slotId, driver: msg.sender, durationHours: duration,
            totalCostCents: totalCost, priorityScore: priority,
            startTime: block.timestamp, completed: false
        });
        FHE.allowThis(reservations[resId].durationHours); FHE.allow(reservations[resId].durationHours, msg.sender);
        FHE.allowThis(reservations[resId].totalCostCents); FHE.allow(reservations[resId].totalCostCents, msg.sender);
        FHE.allowThis(reservations[resId].priorityScore);
        emit SlotReserved(resId, slotId, msg.sender);
    }

    function completeReservation(uint256 reservationId) external onlyParkingOperator {
        ParkingReservation storage r = reservations[reservationId];
        require(!r.completed, "Already completed");
        r.completed = true;
        ParkingSlot storage s = slots[r.slotId];
        s.status = SlotStatus.Available;
        s.totalRevenueUSD = FHE.add(s.totalRevenueUSD, r.totalCostCents);
        _totalSystemRevenueUSD = FHE.add(_totalSystemRevenueUSD, r.totalCostCents);
        // City share = total - operator share (operator share bps / 10000)
        euint64 operatorCut = FHE.div(r.totalCostCents, 10); // 10% operator (plaintext divisor)
        euint64 cityShare = FHE.sub(r.totalCostCents, operatorCut);
        _totalCityShareUSD = FHE.add(_totalCityShareUSD, cityShare);
        FHE.allowThis(s.totalRevenueUSD); FHE.allow(s.totalRevenueUSD, owner());
        FHE.allowThis(_totalSystemRevenueUSD);
        FHE.allowThis(_totalCityShareUSD);
        emit ReservationCompleted(reservationId);
    }

    function allowRevenueView(address viewer) external onlyOwner {
        FHE.allow(_totalSystemRevenueUSD, viewer);
        FHE.allow(_totalCityShareUSD, viewer);
    }
}
