// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateLuxuryYachtCharterMarket
/// @notice Luxury superyacht charter brokerage: encrypted charter rates, encrypted
///         owner earnings, and APA (Advanced Provisioning Allowance) management.
contract PrivateLuxuryYachtCharterMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum YachtClass { Sailing, Motor, Catamaran, Gulet, Megayacht, Superyacht }
    enum CharterStatus { Available, Tentative, Confirmed, InCharter, Completed, Cancelled }

    struct Yacht {
        address owner;
        string yachtName;
        string flag;
        YachtClass yachtClass;
        uint256 loa_dm;                // length overall in decimeters
        euint32 maxGuests;             // encrypted guest capacity
        euint64 weeklyCharterRateUSD;  // encrypted base weekly rate
        euint64 apaPercentageBps;      // encrypted APA % of charter
        euint64 ownerNetUSD;           // encrypted owner net after commission
        euint32 crewCount;             // encrypted crew number
        bool available;
    }

    struct CharterBooking {
        uint256 yachtId;
        address charterer;
        euint64 agreedRateUSD;         // encrypted negotiated rate
        euint64 apaAllowanceUSD;       // encrypted APA funded
        euint64 brokerCommissionUSD;   // encrypted broker cut
        euint32 charterWeeks;          // encrypted duration in weeks
        euint64 totalCharterCostUSD;   // encrypted total cost
        uint256 embarked;
        uint256 disembarked;
        CharterStatus status;
    }

    mapping(uint256 => Yacht) private yachts;
    mapping(uint256 => CharterBooking) private bookings;
    mapping(address => bool) public isCharterer;
    mapping(address => bool) public isBroker;

    uint256 public yachtCount;
    uint256 public bookingCount;
    euint64 private _totalCharterRevenue;
    euint64 private _totalBrokerCommissions;

    event YachtListed(uint256 indexed id, string name, YachtClass yClass);
    event CharterBooked(uint256 indexed id, uint256 yachtId, address charterer);
    event CharterCompleted(uint256 indexed id);

    modifier onlyBroker() {
        require(isBroker[msg.sender] || msg.sender == owner(), "Not broker");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCharterRevenue = FHE.asEuint64(0);
        _totalBrokerCommissions = FHE.asEuint64(0);
        FHE.allowThis(_totalCharterRevenue);
        FHE.allowThis(_totalBrokerCommissions);
        isBroker[msg.sender] = true;
    }

    function addBroker(address b) external onlyOwner { isBroker[b] = true; }
    function registerCharterer(address c) external onlyOwner { isCharterer[c] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function listYacht(
        string calldata name, string calldata flag, YachtClass yClass, uint256 loa,
        externalEuint32 encGuests, bytes calldata gProof,
        externalEuint64 encWeeklyRate, bytes calldata wProof,
        externalEuint64 encAPA, bytes calldata aProof,
        externalEuint32 encCrew, bytes calldata cProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 guests = FHE.fromExternal(encGuests, gProof);
        euint64 rate = FHE.fromExternal(encWeeklyRate, wProof);
        euint64 apa = FHE.fromExternal(encAPA, aProof);
        euint32 crew = FHE.fromExternal(encCrew, cProof);
        id = yachtCount++;
        yachts[id] = Yacht({
            owner: msg.sender, yachtName: name, flag: flag, yachtClass: yClass, loa_dm: loa,
            maxGuests: guests, weeklyCharterRateUSD: rate, apaPercentageBps: apa,
            ownerNetUSD: FHE.asEuint64(0), crewCount: crew, available: true
        });
        FHE.allowThis(yachts[id].maxGuests); FHE.allow(yachts[id].maxGuests, msg.sender);
        FHE.allowThis(yachts[id].weeklyCharterRateUSD); FHE.allow(yachts[id].weeklyCharterRateUSD, msg.sender);
        FHE.allowThis(yachts[id].apaPercentageBps); FHE.allow(yachts[id].apaPercentageBps, msg.sender);
        FHE.allowThis(yachts[id].ownerNetUSD); FHE.allow(yachts[id].ownerNetUSD, msg.sender);
        FHE.allowThis(yachts[id].crewCount);
        emit YachtListed(id, name, yClass);
    }

    function bookCharter(
        uint256 yachtId,
        externalEuint64 encAgreedRate, bytes calldata rProof,
        externalEuint64 encAPA, bytes calldata aProof,
        externalEuint64 encCommission, bytes calldata cProof,
        externalEuint32 encWeeks, bytes calldata wProof,
        uint256 embarkDate
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        require(isCharterer[msg.sender], "Not charterer");
        Yacht storage y = yachts[yachtId];
        require(y.available, "Not available");
        euint64 agreedRate = FHE.fromExternal(encAgreedRate, rProof);
        euint64 apaAllowance = FHE.fromExternal(encAPA, aProof);
        euint64 commission = FHE.fromExternal(encCommission, cProof);
        euint32 charterWeeksDuration = FHE.fromExternal(encWeeks, wProof);
        euint64 total = FHE.add(FHE.add(agreedRate, apaAllowance), commission);
        id = bookingCount++;
        bookings[id] = CharterBooking({
            yachtId: yachtId, charterer: msg.sender,
            agreedRateUSD: agreedRate, apaAllowanceUSD: apaAllowance,
            brokerCommissionUSD: commission, charterWeeks: charterWeeksDuration,
            totalCharterCostUSD: total,
            embarked: embarkDate, disembarked: 0, status: CharterStatus.Confirmed
        });
        y.available = false;
        _totalCharterRevenue = FHE.add(_totalCharterRevenue, agreedRate);
        _totalBrokerCommissions = FHE.add(_totalBrokerCommissions, commission);
        FHE.allowThis(bookings[id].agreedRateUSD); FHE.allow(bookings[id].agreedRateUSD, msg.sender); FHE.allow(bookings[id].agreedRateUSD, y.owner);
        FHE.allowThis(bookings[id].apaAllowanceUSD); FHE.allow(bookings[id].apaAllowanceUSD, msg.sender);
        FHE.allowThis(bookings[id].brokerCommissionUSD);
        FHE.allowThis(bookings[id].charterWeeks); FHE.allow(bookings[id].charterWeeks, msg.sender);
        FHE.allowThis(bookings[id].totalCharterCostUSD); FHE.allow(bookings[id].totalCharterCostUSD, msg.sender);
        FHE.allowThis(_totalCharterRevenue);
        FHE.allowThis(_totalBrokerCommissions);
        emit CharterBooked(id, yachtId, msg.sender);
    }

    function completeCharter(uint256 bookingId) external onlyBroker {
        CharterBooking storage b = bookings[bookingId];
        b.status = CharterStatus.Completed;
        b.disembarked = block.timestamp;
        Yacht storage y = yachts[b.yachtId];
        y.available = true;
        euint64 ownerNet = FHE.sub(b.agreedRateUSD, b.brokerCommissionUSD);
        y.ownerNetUSD = FHE.add(y.ownerNetUSD, ownerNet);
        FHE.allowThis(y.ownerNetUSD); FHE.allow(y.ownerNetUSD, y.owner);
        emit CharterCompleted(bookingId);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalCharterRevenue, viewer);
        FHE.allow(_totalBrokerCommissions, viewer);
    }
}
