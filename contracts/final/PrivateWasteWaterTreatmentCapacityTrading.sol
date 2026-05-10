// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateWasteWaterTreatmentCapacityTrading
/// @notice Encrypted wastewater treatment capacity trading: hidden treatment capacity
///         allocations, confidential effluent quality scores, private discharge permit
///         trading prices, and encrypted industrial polluter fee assessments.
contract PrivateWasteWaterTreatmentCapacityTrading is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum EffluentClass { Domestic, Industrial, Agricultural, Pharmaceutical, Mining }
    enum TreatmentLevel { Primary, Secondary, Tertiary, AdvancedMembrane }

    struct TreatmentFacility {
        address operator;
        string facilityRef;
        string waterAuthority;
        TreatmentLevel treatmentLevel;
        euint32 capacityMLD;           // encrypted capacity in megalitres/day
        euint32 availableCapacityMLD;  // encrypted available capacity
        euint64 pricePerMLDPerMonthUSD;// encrypted capacity price
        euint16 effluentQualityScore;  // encrypted effluent quality
        euint64 totalRevenueUSD;       // encrypted total revenue
        bool active;
    }

    struct CapacityBooking {
        uint256 facilityId;
        address industrialUser;
        EffluentClass effluentClass;
        euint32 bookedCapacityMLD;     // encrypted booked capacity
        euint64 monthlyFeeUSD;         // encrypted monthly fee
        euint64 pollutionPenaltyUSD;   // encrypted excess pollution penalty
        uint256 bookingStart;
        uint256 bookingEnd;
        bool active;
    }

    mapping(uint256 => TreatmentFacility) private facilities;
    mapping(uint256 => CapacityBooking) private bookings;
    mapping(address => bool) public isEnvironmentalAuthority;

    uint256 public facilityCount;
    uint256 public bookingCount;
    euint64 private _totalTreatmentRevenueUSD;
    euint64 private _totalPollutionPenaltiesUSD;

    event FacilityRegistered(uint256 indexed id, TreatmentLevel level);
    event CapacityBooked(uint256 indexed bookingId, uint256 facilityId);
    event PenaltyAssessed(uint256 indexed bookingId, uint256 assessedAt);

    modifier onlyEnvironmentalAuthority() {
        require(isEnvironmentalAuthority[msg.sender] || msg.sender == owner(), "Not env authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalTreatmentRevenueUSD = FHE.asEuint64(0);
        _totalPollutionPenaltiesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalTreatmentRevenueUSD);
        FHE.allowThis(_totalPollutionPenaltiesUSD);
        isEnvironmentalAuthority[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addEnvironmentalAuthority(address a) external onlyOwner { isEnvironmentalAuthority[a] = true; }

    function registerFacility(
        string calldata facilityRef, string calldata waterAuthority, TreatmentLevel treatmentLevel,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint16 encQuality, bytes calldata qProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 capacity = FHE.fromExternal(encCapacity, capProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint16 quality = FHE.fromExternal(encQuality, qProof);
        id = facilityCount++;
        facilities[id].operator = msg.sender;
        facilities[id].facilityRef = facilityRef;
        facilities[id].waterAuthority = waterAuthority;
        facilities[id].treatmentLevel = treatmentLevel;
        facilities[id].capacityMLD = capacity;
        facilities[id].availableCapacityMLD = capacity;
        facilities[id].pricePerMLDPerMonthUSD = price;
        facilities[id].effluentQualityScore = quality;
        facilities[id].totalRevenueUSD = FHE.asEuint64(0);
        facilities[id].active = true;
        FHE.allowThis(facilities[id].capacityMLD); FHE.allow(facilities[id].capacityMLD, msg.sender);
        FHE.allowThis(facilities[id].availableCapacityMLD); FHE.allow(facilities[id].availableCapacityMLD, msg.sender);
        FHE.allowThis(facilities[id].pricePerMLDPerMonthUSD); FHE.allow(facilities[id].pricePerMLDPerMonthUSD, msg.sender);
        FHE.allowThis(facilities[id].effluentQualityScore);
        FHE.allowThis(facilities[id].totalRevenueUSD); FHE.allow(facilities[id].totalRevenueUSD, msg.sender);
        emit FacilityRegistered(id, treatmentLevel);
    }

    function bookCapacity(
        uint256 facilityId, EffluentClass effluentClass,
        externalEuint32 encBookedCap, bytes calldata bcProof,
        uint256 durationMonths
    ) external whenNotPaused nonReentrant returns (uint256 bookingId) {
        TreatmentFacility storage f = facilities[facilityId];
        require(f.active, "Facility not active");
        euint32 bookedCap = FHE.fromExternal(encBookedCap, bcProof);
        ebool capAvailable = FHE.ge(f.availableCapacityMLD, bookedCap);
        euint32 effectiveCap = FHE.select(capAvailable, bookedCap, FHE.asEuint32(0));
        f.availableCapacityMLD = FHE.sub(f.availableCapacityMLD, effectiveCap);
        euint64 monthlyFee = FHE.mul(FHE.asEuint64(1), f.pricePerMLDPerMonthUSD);
        bookingId = bookingCount++;
        bookings[bookingId].facilityId = facilityId;
        bookings[bookingId].industrialUser = msg.sender;
        bookings[bookingId].effluentClass = effluentClass;
        bookings[bookingId].bookedCapacityMLD = effectiveCap;
        bookings[bookingId].monthlyFeeUSD = monthlyFee;
        bookings[bookingId].pollutionPenaltyUSD = FHE.asEuint64(0);
        bookings[bookingId].bookingStart = block.timestamp;
        bookings[bookingId].bookingEnd = block.timestamp + durationMonths * 30 days;
        bookings[bookingId].active = true;
        f.totalRevenueUSD = FHE.add(f.totalRevenueUSD, monthlyFee);
        _totalTreatmentRevenueUSD = FHE.add(_totalTreatmentRevenueUSD, monthlyFee);
        FHE.allowThis(bookings[bookingId].bookedCapacityMLD); FHE.allow(bookings[bookingId].bookedCapacityMLD, msg.sender);
        FHE.allowThis(bookings[bookingId].monthlyFeeUSD); FHE.allow(bookings[bookingId].monthlyFeeUSD, msg.sender); FHE.allow(bookings[bookingId].monthlyFeeUSD, f.operator);
        FHE.allowThis(bookings[bookingId].pollutionPenaltyUSD);
        FHE.allowThis(f.availableCapacityMLD); FHE.allow(f.availableCapacityMLD, f.operator);
        FHE.allowThis(f.totalRevenueUSD); FHE.allow(f.totalRevenueUSD, f.operator);
        FHE.allowThis(_totalTreatmentRevenueUSD);
        emit CapacityBooked(bookingId, facilityId);
    }

    function assessPollutionPenalty(
        uint256 bookingId,
        externalEuint64 encPenalty, bytes calldata proof
    ) external onlyEnvironmentalAuthority nonReentrant {
        CapacityBooking storage b = bookings[bookingId];
        euint64 penalty = FHE.fromExternal(encPenalty, proof);
        b.pollutionPenaltyUSD = FHE.add(b.pollutionPenaltyUSD, penalty);
        _totalPollutionPenaltiesUSD = FHE.add(_totalPollutionPenaltiesUSD, penalty);
        FHE.allowThis(b.pollutionPenaltyUSD); FHE.allow(b.pollutionPenaltyUSD, b.industrialUser);
        FHE.allowThis(_totalPollutionPenaltiesUSD);
        emit PenaltyAssessed(bookingId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalTreatmentRevenueUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalTreatmentRevenueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalPollutionPenaltiesUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalPollutionPenaltiesUSD, viewer);
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