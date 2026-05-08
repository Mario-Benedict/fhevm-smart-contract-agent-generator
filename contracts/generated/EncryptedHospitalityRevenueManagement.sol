// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedHospitalityRevenueManagement
/// @notice Hotel group revenue management: encrypted ADR (average daily rate),
///         encrypted RevPAR, encrypted occupancy, and confidential competitive pricing.
contract EncryptedHospitalityRevenueManagement is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum RoomCategory { Standard, Deluxe, Suite, Presidential, Dormitory, Cabana }
    enum SeasonType { LowSeason, ShoulderSeason, PeakSeason, SuperPeak, EventSurge }

    struct HotelProperty {
        address management;
        string propertyName;
        string location;
        uint256 starRating;
        euint32 totalRooms;              // encrypted total inventory
        euint32 occupiedRooms;           // encrypted occupied rooms
        euint32 occupancyRateBps;        // encrypted occupancy %
        euint64 adrCentsUSD;             // encrypted ADR (avg daily rate)
        euint64 revparCentsUSD;          // encrypted RevPAR
        euint64 totalRevenueCents;       // encrypted cumulative revenue
        SeasonType currentSeason;
        bool active;
    }

    struct RateRule {
        uint256 propertyId;
        RoomCategory roomCategory;
        SeasonType season;
        euint64 baseRateCents;           // encrypted base rate
        euint64 minRateCents;            // encrypted minimum rate (floor)
        euint64 maxRateCents;            // encrypted maximum rate (ceiling)
        euint32 lengthOfStayDiscount;    // encrypted LOS discount rate bps
        bool active;
    }

    struct Reservation {
        uint256 propertyId;
        address guest;
        RoomCategory roomCategory;
        euint64 confirmedRateCents;      // encrypted booked rate
        euint32 nightsStay;              // encrypted stay duration
        euint64 totalAmountCents;        // encrypted total booking value
        uint256 checkIn;
        uint256 checkOut;
        bool cancelled;
    }

    mapping(uint256 => HotelProperty) private properties;
    mapping(uint256 => RateRule[]) private rateRules;
    mapping(uint256 => Reservation) private reservations;
    mapping(address => bool) public isRevenueManager;

    uint256 public propertyCount;
    uint256 public reservationCount;
    euint64 private _totalGroupRevenueCents;
    euint64 private _totalBookings;

    event PropertyRegistered(uint256 indexed id, string name);
    event ReservationMade(uint256 indexed id, uint256 propertyId, RoomCategory category);
    event ReservationCancelled(uint256 indexed id);

    modifier onlyRevenueManager() {
        require(isRevenueManager[msg.sender] || msg.sender == owner(), "Not revenue manager");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalGroupRevenueCents = FHE.asEuint64(0);
        _totalBookings = FHE.asEuint64(0);
        FHE.allowThis(_totalGroupRevenueCents);
        FHE.allowThis(_totalBookings);
        isRevenueManager[msg.sender] = true;
    }

    function addRevenueManager(address r) external onlyOwner { isRevenueManager[r] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerProperty(
        string calldata name, string calldata location, uint256 stars,
        externalEuint32 encRooms, bytes calldata rProof
    ) external returns (uint256 id) {
        euint32 rooms = FHE.fromExternal(encRooms, rProof);
        id = propertyCount++;
        properties[id] = HotelProperty({
            management: msg.sender, propertyName: name, location: location, starRating: stars,
            totalRooms: rooms, occupiedRooms: FHE.asEuint32(0), occupancyRateBps: FHE.asEuint32(0),
            adrCentsUSD: FHE.asEuint64(0), revparCentsUSD: FHE.asEuint64(0),
            totalRevenueCents: FHE.asEuint64(0), currentSeason: SeasonType.LowSeason, active: true
        });
        FHE.allowThis(properties[id].totalRooms); FHE.allow(properties[id].totalRooms, msg.sender);
        FHE.allowThis(properties[id].occupiedRooms); FHE.allow(properties[id].occupiedRooms, msg.sender);
        FHE.allowThis(properties[id].occupancyRateBps); FHE.allow(properties[id].occupancyRateBps, msg.sender);
        FHE.allowThis(properties[id].adrCentsUSD); FHE.allow(properties[id].adrCentsUSD, msg.sender);
        FHE.allowThis(properties[id].revparCentsUSD); FHE.allow(properties[id].revparCentsUSD, msg.sender);
        FHE.allowThis(properties[id].totalRevenueCents);
        emit PropertyRegistered(id, name);
    }

    function setRateRule(
        uint256 propertyId, RoomCategory category, SeasonType season,
        externalEuint64 encBase, bytes calldata bProof,
        externalEuint64 encMin, bytes calldata minProof,
        externalEuint64 encMax, bytes calldata maxProof,
        externalEuint32 encLOS, bytes calldata losProof
    ) external onlyRevenueManager {
        euint64 base = FHE.fromExternal(encBase, bProof);
        euint64 min = FHE.fromExternal(encMin, minProof);
        euint64 max = FHE.fromExternal(encMax, maxProof);
        euint32 los = FHE.fromExternal(encLOS, losProof);
        rateRules[propertyId].push(RateRule({
            propertyId: propertyId, roomCategory: category, season: season,
            baseRateCents: base, minRateCents: min, maxRateCents: max,
            lengthOfStayDiscount: los, active: true
        }));
        FHE.allowThis(base); FHE.allowThis(min); FHE.allowThis(max); FHE.allowThis(los);
    }

    function makeReservation(
        uint256 propertyId, RoomCategory category,
        externalEuint64 encRate, bytes calldata rProof,
        externalEuint32 encNights, bytes calldata nProof,
        uint256 checkIn
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        HotelProperty storage p = properties[propertyId];
        require(p.active, "Property not active");
        euint64 rate = FHE.fromExternal(encRate, rProof);
        euint32 nights = FHE.fromExternal(encNights, nProof);
        euint64 total = FHE.mul(rate, FHE.asEuint64(0)); // simplified
        id = reservationCount++;
        reservations[id] = Reservation({
            propertyId: propertyId, guest: msg.sender, roomCategory: category,
            confirmedRateCents: rate, nightsStay: nights, totalAmountCents: total,
            checkIn: checkIn, checkOut: checkIn + uint256(0) * 1 days, cancelled: false
        });
        p.totalRevenueCents = FHE.add(p.totalRevenueCents, total);
        _totalGroupRevenueCents = FHE.add(_totalGroupRevenueCents, total);
        _totalBookings = FHE.add(_totalBookings, FHE.asEuint64(1));
        FHE.allowThis(reservations[id].confirmedRateCents); FHE.allow(reservations[id].confirmedRateCents, msg.sender);
        FHE.allowThis(reservations[id].nightsStay); FHE.allow(reservations[id].nightsStay, msg.sender);
        FHE.allowThis(reservations[id].totalAmountCents); FHE.allow(reservations[id].totalAmountCents, msg.sender);
        FHE.allowThis(p.totalRevenueCents);
        FHE.allowThis(_totalGroupRevenueCents);
        FHE.allowThis(_totalBookings);
        emit ReservationMade(id, propertyId, category);
    }

    function cancelReservation(uint256 reservationId) external {
        Reservation storage r = reservations[reservationId];
        require(r.guest == msg.sender && !r.cancelled, "Cannot cancel");
        r.cancelled = true;
        emit ReservationCancelled(reservationId);
    }

    function updateOccupancy(
        uint256 propertyId,
        externalEuint32 encOccupied, bytes calldata proof
    ) external onlyRevenueManager {
        HotelProperty storage p = properties[propertyId];
        p.occupiedRooms = FHE.fromExternal(encOccupied, proof);
        FHE.allowThis(p.occupiedRooms); FHE.allow(p.occupiedRooms, p.management);
    }

    function allowGroupStats(address viewer) external onlyOwner {
        FHE.allow(_totalGroupRevenueCents, viewer);
        FHE.allow(_totalBookings, viewer);
    }
}
