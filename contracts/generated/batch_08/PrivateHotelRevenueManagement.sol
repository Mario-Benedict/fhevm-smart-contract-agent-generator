// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateHotelRevenueManagement
/// @notice Hotel revenue management: encrypted room rates per category,
///         encrypted occupancy rates, dynamic encrypted pricing, and ADR tracking.
contract PrivateHotelRevenueManagement is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum RoomCategory { Standard, Deluxe, Suite, Presidential, Penthouse }
    enum BookingStatus { Confirmed, CheckedIn, CheckedOut, Cancelled, NoShow }

    struct RoomInventory {
        RoomCategory category;
        euint16 totalRooms;            // encrypted total room count
        euint16 occupiedRooms;         // encrypted currently occupied
        euint64 baseRateUSD;           // encrypted base nightly rate
        euint64 dynamicRateUSD;        // encrypted current dynamic rate
        euint64 revenueToDate;         // encrypted cumulative revenue
        euint8  occupancyRatePct;      // encrypted occupancy %
        bool active;
    }

    struct Booking {
        address guest;
        RoomCategory category;
        euint64 rateChargedUSD;        // encrypted nightly rate at booking
        euint64 totalChargeUSD;        // encrypted total stay charge
        euint64 depositPaidUSD;        // encrypted deposit
        uint256 checkInDate;
        uint256 checkOutDate;
        uint256 nightsStay;
        BookingStatus status;
        string confirmationCode;
    }

    mapping(RoomCategory => RoomInventory) private inventory;
    mapping(uint256 => Booking) private bookings;
    mapping(address => bool) public isRevenueManager;
    mapping(address => bool) public isFrontDesk;
    uint256 public bookingCount;
    euint64 private _totalHotelRevenue;
    euint64 private _totalDepositHeld;

    event RoomInventorySet(RoomCategory category);
    event BookingCreated(uint256 indexed id, address guest, RoomCategory category);
    event CheckedIn(uint256 indexed id);
    event CheckedOut(uint256 indexed id);
    event DynamicRateUpdated(RoomCategory category);
    event BookingCancelled(uint256 indexed id);

    modifier onlyRevenueManager() {
        require(isRevenueManager[msg.sender] || msg.sender == owner(), "Not revenue manager");
        _;
    }

    modifier onlyFrontDesk() {
        require(isFrontDesk[msg.sender] || msg.sender == owner(), "Not front desk");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalHotelRevenue = FHE.asEuint64(0);
        _totalDepositHeld = FHE.asEuint64(0);
        FHE.allowThis(_totalHotelRevenue);
        FHE.allowThis(_totalDepositHeld);
        isRevenueManager[msg.sender] = true;
        isFrontDesk[msg.sender] = true;
    }

    function addRevenueManager(address r) external onlyOwner { isRevenueManager[r] = true; }
    function addFrontDesk(address f) external onlyOwner { isFrontDesk[f] = true; }

    function setRoomInventory(
        RoomCategory category,
        externalEuint16 encTotal, bytes calldata tPf,
        externalEuint64 encBaseRate, bytes calldata brPf
    ) external onlyRevenueManager {
        euint16 total = FHE.fromExternal(encTotal, tPf);
        euint64 baseRate = FHE.fromExternal(encBaseRate, brPf);
        inventory[category] = RoomInventory({
            category: category, totalRooms: total, occupiedRooms: FHE.asEuint16(0),
            baseRateUSD: baseRate, dynamicRateUSD: baseRate, revenueToDate: FHE.asEuint64(0),
            occupancyRatePct: FHE.asEuint8(0), active: true
        });
        FHE.allowThis(inventory[category].totalRooms);
        FHE.allowThis(inventory[category].occupiedRooms);
        FHE.allowThis(inventory[category].baseRateUSD);
        FHE.allowThis(inventory[category].dynamicRateUSD);
        FHE.allowThis(inventory[category].revenueToDate);
        FHE.allowThis(inventory[category].occupancyRatePct);
        emit RoomInventorySet(category);
    }

    function updateDynamicRate(
        RoomCategory category,
        externalEuint64 encNewRate, bytes calldata proof
    ) external onlyRevenueManager {
        euint64 newRate = FHE.fromExternal(encNewRate, proof);
        inventory[category].dynamicRateUSD = newRate;
        FHE.allowThis(inventory[category].dynamicRateUSD);
        emit DynamicRateUpdated(category);
    }

    function createBooking(
        RoomCategory category, string calldata confCode,
        uint256 checkInTimestamp, uint256 nightsStay,
        externalEuint64 encDeposit, bytes calldata dPf
    ) external nonReentrant returns (uint256 bookingId) {
        require(inventory[category].active, "Category inactive");
        euint64 deposit = FHE.fromExternal(encDeposit, dPf);
        euint64 rate = inventory[category].dynamicRateUSD;
        euint64 totalCharge = FHE.mul(rate, FHE.asEuint64(uint64(nightsStay)));
        bookingId = bookingCount++;
        bookings[bookingId].guest = msg.sender;
        bookings[bookingId].category = category;
        bookings[bookingId].rateChargedUSD = rate;
        bookings[bookingId].totalChargeUSD = totalCharge;
        bookings[bookingId].depositPaidUSD = deposit;
        bookings[bookingId].checkInDate = checkInTimestamp;
        bookings[bookingId].checkOutDate = checkInTimestamp + nightsStay * 1 days;
        bookings[bookingId].nightsStay = nightsStay;
        bookings[bookingId].status = BookingStatus.Confirmed;
        bookings[bookingId].confirmationCode = confCode;
        _totalDepositHeld = FHE.add(_totalDepositHeld, deposit);
        FHE.allowThis(bookings[bookingId].rateChargedUSD);
        FHE.allow(bookings[bookingId].rateChargedUSD, msg.sender);
        FHE.allowThis(bookings[bookingId].totalChargeUSD);
        FHE.allow(bookings[bookingId].totalChargeUSD, msg.sender);
        FHE.allowThis(bookings[bookingId].depositPaidUSD);
        FHE.allow(bookings[bookingId].depositPaidUSD, msg.sender);
        FHE.allowThis(_totalDepositHeld);
        emit BookingCreated(bookingId, msg.sender, category);
    }

    function checkIn(uint256 bookingId) external onlyFrontDesk {
        Booking storage b = bookings[bookingId];
        require(b.status == BookingStatus.Confirmed, "Not confirmed");
        b.status = BookingStatus.CheckedIn;
        inventory[b.category].occupiedRooms = FHE.add(
            inventory[b.category].occupiedRooms, FHE.asEuint16(1)
        );
        FHE.allowThis(inventory[b.category].occupiedRooms);
        emit CheckedIn(bookingId);
    }

    function checkOut(uint256 bookingId) external onlyFrontDesk {
        Booking storage b = bookings[bookingId];
        require(b.status == BookingStatus.CheckedIn, "Not checked in");
        b.status = BookingStatus.CheckedOut;
        _totalHotelRevenue = FHE.add(_totalHotelRevenue, b.totalChargeUSD);
        _totalDepositHeld = FHE.sub(_totalDepositHeld, b.depositPaidUSD);
        inventory[b.category].revenueToDate = FHE.add(inventory[b.category].revenueToDate, b.totalChargeUSD);
        inventory[b.category].occupiedRooms = FHE.sub(
            inventory[b.category].occupiedRooms, FHE.asEuint16(1)
        );
        FHE.allowThis(_totalHotelRevenue);
        FHE.allowThis(_totalDepositHeld);
        FHE.allowThis(inventory[b.category].revenueToDate);
        FHE.allowThis(inventory[b.category].occupiedRooms);
        FHE.allow(b.totalChargeUSD, b.guest);
        emit CheckedOut(bookingId);
    }

    function cancelBooking(uint256 bookingId) external {
        Booking storage b = bookings[bookingId];
        require(msg.sender == b.guest || isFrontDesk[msg.sender], "Unauthorized");
        require(b.status == BookingStatus.Confirmed, "Cannot cancel");
        b.status = BookingStatus.Cancelled;
        _totalDepositHeld = FHE.sub(_totalDepositHeld, b.depositPaidUSD);
        FHE.allowThis(_totalDepositHeld);
        emit BookingCancelled(bookingId);
    }

    function allowBookingDetails(uint256 bookingId, address viewer) external {
        Booking storage b = bookings[bookingId];
        require(msg.sender == b.guest || isFrontDesk[msg.sender] || isRevenueManager[msg.sender], "Unauthorized");
        FHE.allow(b.rateChargedUSD, viewer);
        FHE.allow(b.totalChargeUSD, viewer);
        FHE.allow(b.depositPaidUSD, viewer);
    }

    function allowHotelStats(address viewer) external onlyOwner {
        FHE.allow(_totalHotelRevenue, viewer);
        FHE.allow(_totalDepositHeld, viewer);
    }
}
