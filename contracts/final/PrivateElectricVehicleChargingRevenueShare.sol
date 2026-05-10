// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateElectricVehicleChargingRevenueShare
/// @notice Encrypted EV charging network revenue sharing: hidden session energy dispensed,
///         confidential dynamic pricing per kWh, private network operator vs site host
///         revenue splits, and encrypted grid demand response incentive payments.
contract PrivateElectricVehicleChargingRevenueShare is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ChargerType { Level2AC, DCFC50kW, DCFC150kW, DCFC350kW }
    enum GridSignal { Normal, PeakDemand, OffPeak, DemandResponse }

    struct ChargingStation {
        address siteHost;
        address networkOperator;
        ChargerType chargerType;
        string locationRef;
        euint32 maxPowerkW;            // encrypted max power
        euint64 pricePerKWhUSD;        // encrypted dynamic price per kWh
        euint16 hostShareBps;          // encrypted site host revenue share
        euint64 totalEnergyDispensedKWh; // encrypted total energy
        euint64 totalRevenueUSD;       // encrypted total revenue
        bool active;
    }

    struct ChargingSession {
        uint256 stationId;
        address driver;
        euint64 energyDispensedKWh;    // encrypted energy dispensed
        euint64 sessionCostUSD;        // encrypted session cost
        euint64 hostShareUSD;          // encrypted host share
        euint64 gridIncentiveUSD;      // encrypted demand response incentive
        GridSignal gridSignal;
        uint256 startTime;
        uint256 endTime;
    }

    mapping(uint256 => ChargingStation) private stations;
    mapping(uint256 => ChargingSession) private sessions;
    mapping(address => bool) public isNetworkOperator;

    uint256 public stationCount;
    uint256 public sessionCount;
    euint64 private _totalNetworkRevenueUSD;
    euint64 private _totalEnergyDeliveredKWh;
    euint64 private _totalGridIncentivesUSD;

    event StationRegistered(uint256 indexed id, ChargerType chargerType, string location);
    event ChargingSessionCompleted(uint256 indexed sessionId, uint256 stationId);

    modifier onlyNetworkOperator() {
        require(isNetworkOperator[msg.sender] || msg.sender == owner(), "Not network operator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalNetworkRevenueUSD = FHE.asEuint64(0);
        _totalEnergyDeliveredKWh = FHE.asEuint64(0);
        _totalGridIncentivesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalNetworkRevenueUSD);
        FHE.allowThis(_totalEnergyDeliveredKWh);
        FHE.allowThis(_totalGridIncentivesUSD);
        isNetworkOperator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addNetworkOperator(address op) external onlyOwner { isNetworkOperator[op] = true; }

    function registerStation(
        address siteHost, ChargerType chargerType, string calldata locationRef,
        externalEuint32 encMaxPower, bytes calldata mpProof,
        externalEuint64 encPricePerKWh, bytes calldata ppProof,
        externalEuint16 encHostShare, bytes calldata hsProof
    ) external onlyNetworkOperator whenNotPaused returns (uint256 id) {
        euint32 maxPower = FHE.fromExternal(encMaxPower, mpProof);
        euint64 pricePerKWh = FHE.fromExternal(encPricePerKWh, ppProof);
        euint16 hostShare = FHE.fromExternal(encHostShare, hsProof);
        id = stationCount++;
        stations[id].siteHost = siteHost;
        stations[id].networkOperator = msg.sender;
        stations[id].chargerType = chargerType;
        stations[id].locationRef = locationRef;
        stations[id].maxPowerkW = maxPower;
        stations[id].pricePerKWhUSD = pricePerKWh;
        stations[id].hostShareBps = hostShare;
        stations[id].totalEnergyDispensedKWh = FHE.asEuint64(0);
        stations[id].totalRevenueUSD = FHE.asEuint64(0);
        stations[id].active = true;
        FHE.allowThis(stations[id].maxPowerkW); FHE.allow(stations[id].maxPowerkW, msg.sender);
        FHE.allowThis(stations[id].pricePerKWhUSD); FHE.allow(stations[id].pricePerKWhUSD, siteHost);
        FHE.allowThis(stations[id].hostShareBps); FHE.allow(stations[id].hostShareBps, siteHost);
        FHE.allowThis(stations[id].totalEnergyDispensedKWh); FHE.allow(stations[id].totalEnergyDispensedKWh, siteHost);
        FHE.allowThis(stations[id].totalRevenueUSD); FHE.allow(stations[id].totalRevenueUSD, siteHost); FHE.allow(stations[id].totalRevenueUSD, msg.sender);
        emit StationRegistered(id, chargerType, locationRef);
    }

    function recordChargingSession(
        uint256 stationId, address driver,
        externalEuint64 encEnergy, bytes calldata eProof,
        externalEuint64 encGridIncentive, bytes calldata giProof,
        GridSignal gridSignal,
        uint256 startTime, uint256 endTime
    ) external onlyNetworkOperator nonReentrant returns (uint256 sessionId) {
        ChargingStation storage s = stations[stationId];
        require(s.active, "Station not active");
        euint64 energy = FHE.fromExternal(encEnergy, eProof);
        euint64 gridIncentive = FHE.fromExternal(encGridIncentive, giProof);
        euint64 sessionCost = FHE.mul(energy, s.pricePerKWhUSD);
        euint64 hostShareUSD = FHE.div(sessionCost, 4); // 25% to host (plaintext divisor)
        sessionId = sessionCount++;
        sessions[sessionId].stationId = stationId;
        sessions[sessionId].driver = driver;
        sessions[sessionId].energyDispensedKWh = energy;
        sessions[sessionId].sessionCostUSD = sessionCost;
        sessions[sessionId].hostShareUSD = hostShareUSD;
        sessions[sessionId].gridIncentiveUSD = gridIncentive;
        sessions[sessionId].gridSignal = gridSignal;
        sessions[sessionId].startTime = startTime;
        sessions[sessionId].endTime = endTime;
        s.totalEnergyDispensedKWh = FHE.add(s.totalEnergyDispensedKWh, energy);
        s.totalRevenueUSD = FHE.add(s.totalRevenueUSD, sessionCost);
        _totalNetworkRevenueUSD = FHE.add(_totalNetworkRevenueUSD, sessionCost);
        _totalEnergyDeliveredKWh = FHE.add(_totalEnergyDeliveredKWh, energy);
        _totalGridIncentivesUSD = FHE.add(_totalGridIncentivesUSD, gridIncentive);
        FHE.allowThis(sessions[sessionId].energyDispensedKWh); FHE.allow(sessions[sessionId].energyDispensedKWh, driver);
        FHE.allowThis(sessions[sessionId].sessionCostUSD); FHE.allow(sessions[sessionId].sessionCostUSD, driver);
        FHE.allowThis(sessions[sessionId].hostShareUSD); FHE.allow(sessions[sessionId].hostShareUSD, s.siteHost);
        FHE.allowThis(sessions[sessionId].gridIncentiveUSD);
        FHE.allowThis(s.totalEnergyDispensedKWh); FHE.allow(s.totalEnergyDispensedKWh, s.siteHost);
        FHE.allowThis(s.totalRevenueUSD); FHE.allow(s.totalRevenueUSD, s.siteHost);
        FHE.allowThis(_totalNetworkRevenueUSD);
        FHE.allowThis(_totalEnergyDeliveredKWh);
        FHE.allowThis(_totalGridIncentivesUSD);
        emit ChargingSessionCompleted(sessionId, stationId);
    }

    function allowNetworkStats(address viewer) external onlyOwner {
        FHE.allow(_totalNetworkRevenueUSD, viewer);
        FHE.allow(_totalEnergyDeliveredKWh, viewer);
        FHE.allow(_totalGridIncentivesUSD, viewer);
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