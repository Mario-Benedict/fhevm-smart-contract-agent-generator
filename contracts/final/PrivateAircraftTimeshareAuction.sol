// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAircraftTimeshareAuction
/// @notice Fractional jet ownership auction platform with encrypted flight hour
///         allocations, confidential maintenance cost sharing, and private resale bids.
contract PrivateAircraftTimeshareAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum AircraftClass { LIGHT_JET, MIDSIZE_JET, HEAVY_JET, ULTRA_LONG_RANGE, TURBOPROP }

    struct AircraftAsset {
        AircraftClass class_;
        string tailNumber;
        euint64 totalValueUSD;           // encrypted appraised value
        euint64 annualOperatingCostUSD;  // encrypted annual operating cost
        euint64 totalHoursAllocated;     // encrypted total purchasable hours/year
        euint64 hoursRemaining;          // encrypted hours available
        euint64 maintenanceReserveUSD;   // encrypted maintenance reserve fund
        euint32 flightHoursLogged;       // encrypted total hours flown
        bool active;
    }

    struct OwnershipShare {
        address owner;
        euint64 hoursOwned;          // encrypted hours owned per year
        euint64 purchasePriceUSD;    // encrypted price paid
        euint64 maintenanceShareUSD; // encrypted annual maintenance liability
        euint64 hoursUsed;           // encrypted hours consumed
        euint64 resaleValue;         // encrypted current estimated resale value
        bool active;
    }

    struct SealedBid {
        address bidder;
        uint256 aircraftId;
        uint256 shareId;
        euint64 bidAmountUSD;        // encrypted bid
        euint64 hoursRequested;      // encrypted hours requested
        uint256 submittedAt;
        bool revealed;
        bool won;
    }

    mapping(uint256 => AircraftAsset) private aircraft;
    mapping(uint256 => mapping(uint256 => OwnershipShare)) private shares; // aircraftId => shareId => share
    mapping(bytes32 => SealedBid) private bids;
    mapping(address => bool) public isOperator;
    mapping(address => bool) public isApprovedBidder;

    uint256 public aircraftCount;
    euint64 private _totalFleetValueUSD;
    euint64 private _totalMaintenancePoolUSD;

    event AircraftListed(uint256 indexed id, AircraftClass class_, string tail);
    event BidSubmitted(bytes32 indexed bidKey, uint256 aircraftId);
    event BidAwarded(bytes32 indexed bidKey, address winner);
    event FlightScheduled(uint256 indexed aircraftId, address indexed owner);
    event MaintenanceCostSplit(uint256 indexed aircraftId);

    constructor() Ownable(msg.sender) {
        _totalFleetValueUSD = FHE.asEuint64(0);
        _totalMaintenancePoolUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalFleetValueUSD);
        FHE.allowThis(_totalMaintenancePoolUSD);
        isOperator[msg.sender] = true;
    }

    modifier onlyOperator() { require(isOperator[msg.sender], "Not operator"); _; }

    function listAircraft(
        AircraftClass class_,
        string calldata tailNumber,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint64 encOpCost, bytes calldata ocProof,
        externalEuint64 encTotalHours, bytes calldata thProof
    ) external onlyOperator returns (uint256 id) {
        id = aircraftCount++;
        AircraftAsset storage a = aircraft[id];
        a.class_ = class_;
        a.tailNumber = tailNumber;
        a.totalValueUSD = FHE.fromExternal(encValue, vProof);
        a.annualOperatingCostUSD = FHE.fromExternal(encOpCost, ocProof);
        a.totalHoursAllocated = FHE.fromExternal(encTotalHours, thProof);
        a.hoursRemaining = a.totalHoursAllocated;
        a.maintenanceReserveUSD = FHE.asEuint64(0);
        a.flightHoursLogged = FHE.asEuint32(0);
        a.active = true;
        _totalFleetValueUSD = FHE.add(_totalFleetValueUSD, a.totalValueUSD);
        FHE.allowThis(a.totalValueUSD);
        FHE.allowThis(a.annualOperatingCostUSD);
        FHE.allowThis(a.totalHoursAllocated);
        FHE.allowThis(a.hoursRemaining);
        FHE.allowThis(a.maintenanceReserveUSD);
        FHE.allowThis(a.flightHoursLogged);
        FHE.allowThis(_totalFleetValueUSD);
        emit AircraftListed(id, class_, tailNumber);
    }

    function placeBid(
        uint256 aircraftId,
        externalEuint64 encBid, bytes calldata bProof,
        externalEuint64 encHours, bytes calldata hProof,
        uint256 nonce
    ) external nonReentrant returns (bytes32 bidKey) {
        require(isApprovedBidder[msg.sender], "Not approved");
        require(aircraft[aircraftId].active, "Not listed");
        euint64 bid = FHE.fromExternal(encBid, bProof);
        euint64 flightHours = FHE.fromExternal(encHours, hProof);
        // Ensure hours don't exceed remaining
        ebool withinLimit = FHE.le(flightHours, aircraft[aircraftId].hoursRemaining);
        euint64 actualHours = FHE.select(withinLimit, flightHours, aircraft[aircraftId].hoursRemaining);
        bidKey = keccak256(abi.encodePacked(msg.sender, aircraftId, nonce));
        bids[bidKey] = SealedBid({
            bidder: msg.sender, aircraftId: aircraftId, shareId: 0,
            bidAmountUSD: bid, hoursRequested: actualHours,
            submittedAt: block.timestamp, revealed: false, won: false
        });
        FHE.allowThis(bids[bidKey].bidAmountUSD);
        FHE.allowThis(bids[bidKey].hoursRequested);
        emit BidSubmitted(bidKey, aircraftId);
    }

    function awardBid(bytes32 bidKey, uint256 shareId, uint64 totalHoursPlaintext) external onlyOperator {
        SealedBid storage sb = bids[bidKey];
        require(!sb.revealed, "Already revealed");
        AircraftAsset storage a = aircraft[sb.aircraftId];
        // Allocate hours
        ebool hasHours = FHE.ge(a.hoursRemaining, sb.hoursRequested);
        euint64 allocated = FHE.select(hasHours, sb.hoursRequested, a.hoursRemaining);
        a.hoursRemaining = FHE.sub(a.hoursRemaining, allocated);
        // Calculate maintenance share
        euint64 maintenanceShare = totalHoursPlaintext > 0
            ? FHE.div(FHE.mul(a.annualOperatingCostUSD, allocated), totalHoursPlaintext)
            : FHE.asEuint64(0);
        uint256 sid = shareId;
        shares[sb.aircraftId][sid] = OwnershipShare({
            owner: sb.bidder, hoursOwned: allocated, purchasePriceUSD: sb.bidAmountUSD,
            maintenanceShareUSD: maintenanceShare, hoursUsed: FHE.asEuint64(0),
            resaleValue: sb.bidAmountUSD, active: true
        });
        a.maintenanceReserveUSD = FHE.add(a.maintenanceReserveUSD, maintenanceShare);
        sb.revealed = true;
        sb.won = true;
        _totalMaintenancePoolUSD = FHE.add(_totalMaintenancePoolUSD, maintenanceShare);
        FHE.allowThis(a.hoursRemaining);
        FHE.allowThis(a.maintenanceReserveUSD);
        FHE.allowThis(shares[sb.aircraftId][sid].hoursOwned);
        FHE.allow(shares[sb.aircraftId][sid].hoursOwned, sb.bidder);
        FHE.allowThis(shares[sb.aircraftId][sid].purchasePriceUSD);
        FHE.allow(shares[sb.aircraftId][sid].purchasePriceUSD, sb.bidder);
        FHE.allowThis(shares[sb.aircraftId][sid].maintenanceShareUSD);
        FHE.allow(shares[sb.aircraftId][sid].maintenanceShareUSD, sb.bidder);
        FHE.allowThis(shares[sb.aircraftId][sid].hoursUsed);
        FHE.allow(shares[sb.aircraftId][sid].hoursUsed, sb.bidder);
        FHE.allowThis(_totalMaintenancePoolUSD);
        emit BidAwarded(bidKey, sb.bidder);
    }

    function logFlight(uint256 aircraftId, uint256 shareId, externalEuint64 encHoursFlown, bytes calldata hProof) external {
        OwnershipShare storage sh = shares[aircraftId][shareId];
        require(sh.owner == msg.sender && sh.active, "Not owner");
        euint64 hoursFlown = FHE.fromExternal(encHoursFlown, hProof);
        ebool withinOwned = FHE.le(FHE.add(sh.hoursUsed, hoursFlown), sh.hoursOwned);
        euint64 actual = FHE.select(withinOwned, hoursFlown, FHE.sub(sh.hoursOwned, sh.hoursUsed));
        sh.hoursUsed = FHE.add(sh.hoursUsed, actual);
        aircraft[aircraftId].flightHoursLogged = FHE.add(aircraft[aircraftId].flightHoursLogged, FHE.asEuint32(uint32(0)));
        FHE.allowThis(sh.hoursUsed);
        FHE.allow(sh.hoursUsed, msg.sender);
        FHE.allowThis(aircraft[aircraftId].flightHoursLogged);
        emit FlightScheduled(aircraftId, msg.sender);
    }

    function approveBidder(address b) external onlyOwner { isApprovedBidder[b] = true; }
    function addOperator(address o) external onlyOwner { isOperator[o] = true; }
    function allowFleetStats(address analyst) external onlyOwner {
        FHE.allow(_totalFleetValueUSD, analyst);
        FHE.allow(_totalMaintenancePoolUSD, analyst);
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