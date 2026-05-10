// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAirTrafficSlotAuction
/// @notice Airport slot coordinator: airlines bid confidentially for
///         landing/takeoff slots. Bids, willingness-to-pay, and route
///         profitability scores are encrypted.
contract PrivateAirTrafficSlotAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SlotType { Arrival, Departure, TurnaroundPair }
    enum SlotStatus { Available, UnderBid, Awarded, Cancelled }
    enum AircraftCategory { NarrowBody, WidBody, VeryLargeAircraft, RegionalJet, Cargo }

    struct AirportSlot {
        uint256 slotId;
        string airportICAO;
        SlotType slotType;
        uint256 scheduledUTC;       // Unix timestamp of slot
        AircraftCategory maxCategory;
        euint64 reserveValueUSD;    // encrypted reserve price
        euint32 noiseQuotaPoints;   // encrypted noise quota consumed
        SlotStatus status;
        address awardedAirline;
    }

    struct SlotBid {
        address airline;
        uint256 slotId;
        euint64 bidValueUSD;          // encrypted bid
        euint32 routeProfitScoreBps;  // encrypted route profitability
        euint8 frequencyPerSeason;    // encrypted planned frequency
        AircraftCategory aircraftCat;
        bool active;
    }

    struct AirlineProfile {
        euint64 cumulativeSlotSpend;  // encrypted total spend at airport
        euint32 onTimePerformanceBps; // encrypted OTP rating
        euint16 slotsHeldCount;       // encrypted slot count
        bool approved;
    }

    mapping(uint256 => AirportSlot) private slots;
    mapping(uint256 => SlotBid[]) private slotBids;
    mapping(address => AirlineProfile) private airlines;
    mapping(address => bool) public isSlotCoordinator;

    uint256 public slotCount;
    euint64 private _totalSlotRevenue;
    euint32 private _totalNoiseQuotaAllocated;

    event SlotCreated(uint256 indexed slotId, string airport, SlotType slotType);
    event BidPlaced(uint256 indexed slotId, address airline);
    event SlotAwarded(uint256 indexed slotId, address airline);
    event SlotReturned(uint256 indexed slotId, address airline);

    modifier onlyCoordinator() {
        require(isSlotCoordinator[msg.sender] || msg.sender == owner(), "Not coordinator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSlotRevenue = FHE.asEuint64(0);
        _totalNoiseQuotaAllocated = FHE.asEuint32(0);
        FHE.allowThis(_totalSlotRevenue);
        FHE.allowThis(_totalNoiseQuotaAllocated);
        isSlotCoordinator[msg.sender] = true;
    }

    function addCoordinator(address c) external onlyOwner { isSlotCoordinator[c] = true; }

    function approveAirline(address airline, externalEuint32 encOTP, bytes calldata proof) external onlyCoordinator {
        euint32 otp = FHE.fromExternal(encOTP, proof);
        airlines[airline].onTimePerformanceBps = otp;
        airlines[airline].approved = true;
        airlines[airline].cumulativeSlotSpend = FHE.asEuint64(0);
        airlines[airline].slotsHeldCount = FHE.asEuint16(0);
        FHE.allowThis(airlines[airline].onTimePerformanceBps);
        FHE.allow(airlines[airline].onTimePerformanceBps, airline);
        FHE.allowThis(airlines[airline].cumulativeSlotSpend);
        FHE.allow(airlines[airline].cumulativeSlotSpend, airline);
        FHE.allowThis(airlines[airline].slotsHeldCount);
        FHE.allow(airlines[airline].slotsHeldCount, airline);
    }

    function createSlot(
        string calldata airportICAO,
        SlotType slotType,
        uint256 scheduledUTC,
        AircraftCategory maxCat,
        externalEuint64 encReserve, bytes calldata resProof,
        externalEuint32 encNoisePoints, bytes calldata noiseProof
    ) external onlyCoordinator returns (uint256 slotId) {
        euint64 reserve = FHE.fromExternal(encReserve, resProof);
        euint32 noisePoints = FHE.fromExternal(encNoisePoints, noiseProof);

        slotId = slotCount++;
        AirportSlot storage s = slots[slotId];
        s.slotId = slotId;
        s.airportICAO = airportICAO;
        s.slotType = slotType;
        s.scheduledUTC = scheduledUTC;
        s.maxCategory = maxCat;
        s.reserveValueUSD = reserve;
        s.noiseQuotaPoints = noisePoints;
        s.status = SlotStatus.Available;

        FHE.allowThis(s.reserveValueUSD);
        FHE.allowThis(s.noiseQuotaPoints);

        emit SlotCreated(slotId, airportICAO, slotType);
    }

    function placeBid(
        uint256 slotId,
        externalEuint64 encBid, bytes calldata bidProof,
        externalEuint32 encRouteScore, bytes calldata routeProof,
        externalEuint8 encFrequency, bytes calldata freqProof,
        AircraftCategory aircraftCat
    ) external nonReentrant {
        require(airlines[msg.sender].approved, "Airline not approved");
        AirportSlot storage slot = slots[slotId];
        require(slot.status == SlotStatus.Available || slot.status == SlotStatus.UnderBid, "Not biddable");

        euint64 bid = FHE.fromExternal(encBid, bidProof);
        euint32 routeScore = FHE.fromExternal(encRouteScore, routeProof);
        euint8 frequency = FHE.fromExternal(encFrequency, freqProof);

        // Bid must exceed reserve
        ebool meetsReserve = FHE.ge(bid, slot.reserveValueUSD);
        euint64 effectiveBid = FHE.select(meetsReserve, bid, FHE.asEuint64(0));

        uint256 bidIdx = slotBids[slotId].length;
        slotBids[slotId].push(SlotBid({
            airline: msg.sender,
            slotId: slotId,
            bidValueUSD: effectiveBid,
            routeProfitScoreBps: routeScore,
            frequencyPerSeason: frequency,
            aircraftCat: aircraftCat,
            active: true
        }));

        slot.status = SlotStatus.UnderBid;

        FHE.allowThis(slotBids[slotId][bidIdx].bidValueUSD);
        FHE.allow(slotBids[slotId][bidIdx].bidValueUSD, msg.sender);
        FHE.allowThis(slotBids[slotId][bidIdx].routeProfitScoreBps);
        FHE.allow(slotBids[slotId][bidIdx].routeProfitScoreBps, msg.sender);
        FHE.allowThis(slotBids[slotId][bidIdx].frequencyPerSeason);

        emit BidPlaced(slotId, msg.sender);
    }

    function awardSlot(uint256 slotId, uint256 bidIdx) external onlyCoordinator nonReentrant {
        AirportSlot storage slot = slots[slotId];
        require(slot.status == SlotStatus.UnderBid, "Not under bid");

        SlotBid storage winBid = slotBids[slotId][bidIdx];
        slot.awardedAirline = winBid.airline;
        slot.status = SlotStatus.Awarded;

        _totalSlotRevenue = FHE.add(_totalSlotRevenue, winBid.bidValueUSD);
        _totalNoiseQuotaAllocated = FHE.add(_totalNoiseQuotaAllocated, slot.noiseQuotaPoints);

        airlines[winBid.airline].cumulativeSlotSpend = FHE.add(
            airlines[winBid.airline].cumulativeSlotSpend, winBid.bidValueUSD
        );
        airlines[winBid.airline].slotsHeldCount = FHE.add(
            airlines[winBid.airline].slotsHeldCount, FHE.asEuint16(1)
        );

        FHE.allow(winBid.bidValueUSD, winBid.airline);
        FHE.allowThis(_totalSlotRevenue);
        FHE.allowThis(_totalNoiseQuotaAllocated);
        FHE.allowThis(airlines[winBid.airline].cumulativeSlotSpend);
        FHE.allowThis(airlines[winBid.airline].slotsHeldCount);

        emit SlotAwarded(slotId, winBid.airline);
    }

    function returnSlot(uint256 slotId) external {
        AirportSlot storage slot = slots[slotId];
        require(slot.awardedAirline == msg.sender, "Not slot holder");
        require(slot.status == SlotStatus.Awarded, "Not awarded");
        slot.status = SlotStatus.Available;
        slot.awardedAirline = address(0);
        airlines[msg.sender].slotsHeldCount = FHE.sub(airlines[msg.sender].slotsHeldCount, FHE.asEuint16(1));
        FHE.allowThis(airlines[msg.sender].slotsHeldCount);
        emit SlotReturned(slotId, msg.sender);
    }

    function allowAirportStats(address viewer) external onlyOwner {
        FHE.allow(_totalSlotRevenue, viewer);
        FHE.allow(_totalNoiseQuotaAllocated, viewer);
    }

    function allowAirlineProfile(address viewer) external {
        FHE.allow(airlines[msg.sender].cumulativeSlotSpend, viewer);
        FHE.allow(airlines[msg.sender].onTimePerformanceBps, viewer);
        FHE.allow(airlines[msg.sender].slotsHeldCount, viewer);
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