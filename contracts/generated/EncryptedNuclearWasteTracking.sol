// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedNuclearWasteTracking
/// @notice Regulatory-grade nuclear waste manifest: encrypted radioactivity levels,
///         encrypted geolocation of disposal sites, encrypted decay timeline projections,
///         and multi-authority clearance chain for transport authorization.
contract EncryptedNuclearWasteTracking is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant REGULATOR_ROLE = keccak256("REGULATOR_ROLE");
    bytes32 public constant TRANSPORTER_ROLE = keccak256("TRANSPORTER_ROLE");
    bytes32 public constant SITE_OPERATOR_ROLE = keccak256("SITE_OPERATOR_ROLE");

    struct WasteCanister {
        string manifestId;
        string wasteType;          // e.g. "High-Level", "Low-Level", "TRU"
        euint64 radioactivityBq;   // encrypted Becquerels
        euint64 halfLifeYears;     // encrypted half-life
        euint64 temperatureCelsius;// encrypted current temperature
        euint64 siteLatEncoded;    // encrypted latitude (scaled integer)
        euint64 siteLonEncoded;    // encrypted longitude (scaled integer)
        euint64 massKg;            // encrypted mass
        uint256 packagingDate;
        uint256 nextInspectionDue;
        bool transportAuthorized;
        bool disposed;
        address currentCustodian;
    }

    struct TransportManifest {
        uint256 canisterId;
        address transporter;
        address destinationOperator;
        euint64 distanceKm;        // encrypted transport distance
        euint64 riskScore;         // encrypted risk assessment (0-1000)
        uint256 dispatchTime;
        uint256 estimatedArrival;
        bool completed;
        bool regulatorApproved;
        bool siteApproved;
    }

    mapping(uint256 => WasteCanister) private canisters;
    mapping(uint256 => TransportManifest) private transports;
    mapping(uint256 => euint64) private _decayProjections; // canisterId => projected remaining activity
    euint64 private _totalNetworkRadioactivity;
    uint256 public canisterCount;
    uint256 public transportCount;

    event CanisterRegistered(uint256 indexed id, string manifestId, string wasteType);
    event TransportRequested(uint256 indexed transportId, uint256 canisterId);
    event TransportApproved(uint256 indexed transportId);
    event TransportCompleted(uint256 indexed transportId);
    event InspectionRecorded(uint256 indexed canisterId);
    event DisposalFinalised(uint256 indexed canisterId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REGULATOR_ROLE, msg.sender);
        _totalNetworkRadioactivity = FHE.asEuint64(0);
        FHE.allowThis(_totalNetworkRadioactivity);
    }

    function registerCanister(
        string calldata manifestId,
        string calldata wasteType,
        externalEuint64 encActivity, bytes calldata aProof,
        externalEuint64 encHalfLife, bytes calldata hlProof,
        externalEuint64 encMass, bytes calldata mProof,
        externalEuint64 encLat, bytes calldata latProof,
        externalEuint64 encLon, bytes calldata lonProof,
        uint256 nextInspection
    ) external onlyRole(SITE_OPERATOR_ROLE) returns (uint256 id) {
        euint64 activity = FHE.fromExternal(encActivity, aProof);
        euint64 halfLife = FHE.fromExternal(encHalfLife, hlProof);
        euint64 mass = FHE.fromExternal(encMass, mProof);
        euint64 lat = FHE.fromExternal(encLat, latProof);
        euint64 lon = FHE.fromExternal(encLon, lonProof);
        id = canisterCount++;
        canisters[id] = WasteCanister({
            manifestId: manifestId, wasteType: wasteType,
            radioactivityBq: activity, halfLifeYears: halfLife,
            temperatureCelsius: FHE.asEuint64(20),
            siteLatEncoded: lat, siteLonEncoded: lon,
            massKg: mass,
            packagingDate: block.timestamp,
            nextInspectionDue: nextInspection,
            transportAuthorized: false, disposed: false,
            currentCustodian: msg.sender
        });
        _decayProjections[id] = activity;
        _totalNetworkRadioactivity = FHE.add(_totalNetworkRadioactivity, activity);
        FHE.allowThis(canisters[id].radioactivityBq);
        FHE.allowThis(canisters[id].halfLifeYears);
        FHE.allowThis(canisters[id].temperatureCelsius);
        FHE.allowThis(canisters[id].siteLatEncoded);
        FHE.allowThis(canisters[id].siteLonEncoded);
        FHE.allowThis(canisters[id].massKg);
        FHE.allowThis(_decayProjections[id]);
        FHE.allowThis(_totalNetworkRadioactivity);
        emit CanisterRegistered(id, manifestId, wasteType);
    }

    function recordInspection(
        uint256 canisterId,
        externalEuint64 encCurrentActivity, bytes calldata aProof,
        externalEuint64 encTemperature, bytes calldata tProof,
        uint256 nextInspectionDue
    ) external onlyRole(REGULATOR_ROLE) {
        WasteCanister storage c = canisters[canisterId];
        euint64 currentActivity = FHE.fromExternal(encCurrentActivity, aProof);
        euint64 temperature = FHE.fromExternal(encTemperature, tProof);
        // Update total network radioactivity
        _totalNetworkRadioactivity = FHE.sub(_totalNetworkRadioactivity, c.radioactivityBq);
        c.radioactivityBq = currentActivity;
        _totalNetworkRadioactivity = FHE.add(_totalNetworkRadioactivity, currentActivity);
        c.temperatureCelsius = temperature;
        c.nextInspectionDue = nextInspectionDue;
        _decayProjections[canisterId] = FHE.div(currentActivity, 2); // rough next-half-life estimate
        FHE.allowThis(c.radioactivityBq);
        FHE.allowThis(c.temperatureCelsius);
        FHE.allowThis(_decayProjections[canisterId]);
        FHE.allowThis(_totalNetworkRadioactivity);
        emit InspectionRecorded(canisterId);
    }

    function requestTransport(
        uint256 canisterId,
        address destinationOperator,
        externalEuint64 encDistance, bytes calldata dProof,
        externalEuint64 encRisk, bytes calldata rProof,
        uint256 estimatedArrival
    ) external onlyRole(TRANSPORTER_ROLE) returns (uint256 transportId) {
        require(!canisters[canisterId].disposed, "Already disposed");
        euint64 distance = FHE.fromExternal(encDistance, dProof);
        euint64 risk = FHE.fromExternal(encRisk, rProof);
        transportId = transportCount++;
        transports[transportId] = TransportManifest({
            canisterId: canisterId, transporter: msg.sender,
            destinationOperator: destinationOperator,
            distanceKm: distance, riskScore: risk,
            dispatchTime: block.timestamp,
            estimatedArrival: estimatedArrival,
            completed: false, regulatorApproved: false, siteApproved: false
        });
        FHE.allowThis(transports[transportId].distanceKm);
        FHE.allowThis(transports[transportId].riskScore);
        emit TransportRequested(transportId, canisterId);
    }

    function approveTransport(uint256 transportId) external {
        TransportManifest storage t = transports[transportId];
        if (hasRole(REGULATOR_ROLE, msg.sender)) {
            t.regulatorApproved = true;
        } else if (hasRole(SITE_OPERATOR_ROLE, msg.sender) && msg.sender == t.destinationOperator) {
            t.siteApproved = true;
        } else {
            revert("Not authorized to approve");
        }
        if (t.regulatorApproved && t.siteApproved) {
            canisters[t.canisterId].transportAuthorized = true;
            emit TransportApproved(transportId);
        }
    }

    function completeTransport(uint256 transportId) external onlyRole(TRANSPORTER_ROLE) {
        TransportManifest storage t = transports[transportId];
        require(t.regulatorApproved && t.siteApproved, "Not approved");
        t.completed = true;
        canisters[t.canisterId].currentCustodian = t.destinationOperator;
        canisters[t.canisterId].transportAuthorized = false;
        emit TransportCompleted(transportId);
    }

    function finaliseDisposal(uint256 canisterId) external onlyRole(REGULATOR_ROLE) {
        WasteCanister storage c = canisters[canisterId];
        _totalNetworkRadioactivity = FHE.sub(_totalNetworkRadioactivity, c.radioactivityBq);
        c.disposed = true;
        FHE.allowThis(_totalNetworkRadioactivity);
        emit DisposalFinalised(canisterId);
    }

    function grantRegulatorView(uint256 canisterId, address regulator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        FHE.allow(canisters[canisterId].radioactivityBq, regulator);
        FHE.allow(canisters[canisterId].siteLatEncoded, regulator);
        FHE.allow(canisters[canisterId].siteLonEncoded, regulator);
        FHE.allow(canisters[canisterId].massKg, regulator);
    }
}
