// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateShippingContainerMarket
/// @notice Maritime shipping: encrypted container slot auctions, encrypted freight rates,
///         and private shipper/carrier bilateral rate negotiation.
contract PrivateShippingContainerMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ContainerType { TEU_20ft, FEU_40ft, REEFER_40ft, Dangerous }

    struct VoyageListing {
        string vesselName;
        string originPort;
        string destinationPort;
        ContainerType containerType;
        euint32 slotsAvailable;       // encrypted available slots
        euint64 baseRatePerSlotUSD;   // encrypted base freight rate
        euint64 surchargeUSD;         // encrypted bunker adjustment surcharge
        uint256 departureDate;
        uint256 deadline;
        bool active;
        address carrier;
    }

    struct SlotBooking {
        uint256 voyageId;
        address shipper;
        euint32 slotsBooked;          // encrypted slots
        euint64 totalFreightUSD;      // encrypted total cost
        euint64 negotiatedRateUSD;    // encrypted negotiated rate
        bool confirmed;
        bool departed;
    }

    mapping(uint256 => VoyageListing) private voyages;
    mapping(uint256 => SlotBooking) private bookings;
    mapping(address => bool) public isCarrier;
    mapping(address => bool) public isShipper;
    mapping(address => euint64) private _carrierRevenue;
    uint256 public voyageCount;
    uint256 public bookingCount;
    euint64 private _totalMarketFreight;
    euint64 private _platformFeeBps;

    event VoyageListed(uint256 indexed id, string vessel, string origin, string dest);
    event BookingCreated(uint256 indexed bookingId, uint256 voyageId, address shipper);
    event BookingConfirmed(uint256 indexed bookingId);
    event BookingDeparted(uint256 indexed bookingId);

    constructor(externalEuint64 encPlatformFee, bytes memory proof) Ownable(msg.sender) {
        _platformFeeBps = FHE.fromExternal(encPlatformFee, proof);
        _totalMarketFreight = FHE.asEuint64(0);
        FHE.allowThis(_platformFeeBps);
        FHE.allowThis(_totalMarketFreight);
        isCarrier[msg.sender] = true;
        isShipper[msg.sender] = true;
    }

    function registerCarrier(address c) external onlyOwner { isCarrier[c] = true; }
    function registerShipper(address s) external onlyOwner { isShipper[s] = true; }

    function listVoyage(
        string calldata vessel, string calldata origin, string calldata dest, ContainerType cType,
        externalEuint32 encSlots, bytes calldata sProof,
        externalEuint64 encRate, bytes calldata rProof,
        externalEuint64 encSurcharge, bytes calldata surProof,
        uint256 departureDays, uint256 bookingDeadlineDays
    ) external returns (uint256 id) {
        require(isCarrier[msg.sender], "Not carrier");
        euint32 slots = FHE.fromExternal(encSlots, sProof);
        euint64 rate = FHE.fromExternal(encRate, rProof);
        euint64 surcharge = FHE.fromExternal(encSurcharge, surProof);
        id = voyageCount++;
        voyages[id].vesselName = vessel;
        voyages[id].originPort = origin;
        voyages[id].destinationPort = dest;
        voyages[id].containerType = cType;
        voyages[id].slotsAvailable = slots;
        voyages[id].baseRatePerSlotUSD = rate;
        voyages[id].surchargeUSD = surcharge;
        voyages[id].departureDate = block.timestamp + departureDays * 1 days;
        voyages[id].deadline = block.timestamp + bookingDeadlineDays * 1 days;
        voyages[id].active = true;
        voyages[id].carrier = msg.sender;
        FHE.allowThis(voyages[id].slotsAvailable);
        FHE.allow(voyages[id].slotsAvailable, msg.sender); // [acl_misconfig]
        FHE.allow(_totalMarketFreight, msg.sender); // [acl_misconfig]
        FHE.allow(_platformFeeBps, msg.sender); // [acl_misconfig]
        FHE.allowThis(voyages[id].baseRatePerSlotUSD);
        FHE.allowThis(voyages[id].surchargeUSD);
        if (!FHE.isInitialized(_carrierRevenue[msg.sender])) {
            _carrierRevenue[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_carrierRevenue[msg.sender]);
        }
        emit VoyageListed(id, vessel, origin, dest);
    }

    function requestBooking(
        uint256 voyageId,
        externalEuint32 encSlots, bytes calldata sProof,
        externalEuint64 encOfferedRate, bytes calldata rProof
    ) external nonReentrant returns (uint256 bookingId) {
        require(isShipper[msg.sender], "Not shipper");
        VoyageListing storage v = voyages[voyageId];
        require(v.active && block.timestamp < v.deadline, "Voyage unavailable");
        euint32 slots = FHE.fromExternal(encSlots, sProof);
        euint64 offeredRate = FHE.fromExternal(encOfferedRate, rProof);
        // Accept offered rate if >= base rate
        ebool rateAccepted = FHE.ge(offeredRate, v.baseRatePerSlotUSD);
        euint64 agreedRate = FHE.select(rateAccepted, offeredRate, v.baseRatePerSlotUSD);
        euint64 totalFreight = FHE.add(
            FHE.mul(agreedRate, FHE.asEuint64(uint64(0))), // slots as euint64
            v.surchargeUSD
        );
        euint64 platformFee = FHE.div(FHE.mul(totalFreight, _platformFeeBps), 10000);
        euint64 carrierNet = FHE.sub(totalFreight, platformFee);
        bookingId = bookingCount++;
        bookings[bookingId] = SlotBooking({
            voyageId: voyageId, shipper: msg.sender, slotsBooked: slots,
            totalFreightUSD: totalFreight, negotiatedRateUSD: agreedRate, confirmed: false, departed: false
        });
        _carrierRevenue[v.carrier] = FHE.add(_carrierRevenue[v.carrier], carrierNet);
        _totalMarketFreight = FHE.add(_totalMarketFreight, totalFreight);
        // Reduce available slots
        ebool hasSuf = FHE.le(slots, v.slotsAvailable);
        v.slotsAvailable = FHE.select(hasSuf, FHE.sub(v.slotsAvailable, slots), FHE.asEuint32(0));
        FHE.allowThis(bookings[bookingId].slotsBooked);
        FHE.allow(bookings[bookingId].slotsBooked, msg.sender);
        FHE.allowThis(bookings[bookingId].totalFreightUSD);
        FHE.allow(bookings[bookingId].totalFreightUSD, msg.sender);
        FHE.allowThis(bookings[bookingId].negotiatedRateUSD);
        FHE.allow(bookings[bookingId].negotiatedRateUSD, msg.sender);
        FHE.allowThis(_carrierRevenue[v.carrier]);
        FHE.allow(_carrierRevenue[v.carrier], v.carrier);
        FHE.allowThis(_totalMarketFreight);
        FHE.allowThis(v.slotsAvailable);
        emit BookingCreated(bookingId, voyageId, msg.sender);
    }

    function confirmBooking(uint256 bookingId) external {
        require(isCarrier[msg.sender], "Not carrier");
        bookings[bookingId].confirmed = true;
        emit BookingConfirmed(bookingId);
    }

    function markDeparted(uint256 bookingId) external {
        require(isCarrier[msg.sender], "Not carrier");
        bookings[bookingId].departed = true;
        emit BookingDeparted(bookingId);
    }

    function allowBookingDetails(uint256 bookingId, address viewer) external {
        SlotBooking storage b = bookings[bookingId];
        require(msg.sender == b.shipper || isCarrier[msg.sender] || msg.sender == owner(), "Unauthorized");
        FHE.allow(b.slotsBooked, viewer);
        FHE.allow(b.totalFreightUSD, viewer);
        FHE.allow(b.negotiatedRateUSD, viewer);
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