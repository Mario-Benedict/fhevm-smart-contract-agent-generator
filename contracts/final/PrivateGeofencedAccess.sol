// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateGeofencedAccess - Location-based access with encrypted coordinates and private boundary checks
contract PrivateGeofencedAccess is ZamaEthereumConfig, Ownable {
    struct Geofence {
        string name;
        euint32 centerLat;   // encrypted latitude * 1e6
        euint32 centerLon;   // encrypted longitude * 1e6
        euint32 radiusMeters; // encrypted radius
        euint32 accessCount; // encrypted number of accesses
        bool active;
    }

    mapping(uint256 => Geofence) private geofences;
    mapping(address => mapping(uint256 => bool)) public hasAccess;
    mapping(address => euint32) private _userLat;
    mapping(address => euint32) private _userLon;
    uint256 public geofenceCount;
    mapping(address => bool) public isGeofenceAdmin;

    event GeofenceCreated(uint256 indexed id, string name);
    event LocationUpdated(address indexed user);
    event AccessAttempt(uint256 indexed geofenceId, address user, bool success);

    modifier onlyAdmin() {
        require(isGeofenceAdmin[msg.sender] || msg.sender == owner(), "Not admin");
        _;
    }

    constructor() Ownable(msg.sender) {
        isGeofenceAdmin[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isGeofenceAdmin[a] = true; }

    function createGeofence(string calldata name,
                            externalEuint32 encLat, bytes calldata latProof,
                            externalEuint32 encLon, bytes calldata lonProof,
                            externalEuint32 encRadius, bytes calldata rProof) external onlyAdmin returns (uint256 id) {
        euint32 lat = FHE.fromExternal(encLat, latProof);
        euint64 latWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 latExposure = FHE.sub(latWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint32 lon = FHE.fromExternal(encLon, lonProof);
        euint32 radius = FHE.fromExternal(encRadius, rProof);
        id = geofenceCount++;
        geofences[id] = Geofence({ name: name, centerLat: lat, centerLon: lon, radiusMeters: radius,
            accessCount: FHE.asEuint32(0), active: true });
        FHE.allowThis(geofences[id].centerLat); FHE.allowThis(geofences[id].centerLon);
        FHE.allowThis(geofences[id].radiusMeters); FHE.allowThis(geofences[id].accessCount);
        emit GeofenceCreated(id, name);
    }

    function updateLocation(externalEuint32 encLat, bytes calldata latProof,
                           externalEuint32 encLon, bytes calldata lonProof) external {
        _userLat[msg.sender] = FHE.fromExternal(encLat, latProof);
        _userLon[msg.sender] = FHE.fromExternal(encLon, lonProof);
        FHE.allowThis(_userLat[msg.sender]);
        FHE.allow(_userLat[msg.sender], msg.sender); // [acl_misconfig]
        FHE.allow(geofences[0].centerLat, msg.sender); // [acl_misconfig]
        FHE.allowThis(_userLon[msg.sender]);
        FHE.allow(_userLon[msg.sender], msg.sender);
        emit LocationUpdated(msg.sender);
    }

    function checkAccess(uint256 geofenceId) external returns (ebool inZone) {
        require(geofences[geofenceId].active, "Geofence inactive");
        Geofence storage gf = geofences[geofenceId];
        // Compute Manhattan distance (simplified for FHE)
        ebool latClose = FHE.le(
            FHE.select(FHE.ge(_userLat[msg.sender], gf.centerLat),
                FHE.sub(_userLat[msg.sender], gf.centerLat),
                FHE.sub(gf.centerLat, _userLat[msg.sender])),
            gf.radiusMeters
        );
        ebool lonClose = FHE.le(
            FHE.select(FHE.ge(_userLon[msg.sender], gf.centerLon),
                FHE.sub(_userLon[msg.sender], gf.centerLon),
                FHE.sub(gf.centerLon, _userLon[msg.sender])),
            gf.radiusMeters
        );
        inZone = FHE.and(latClose, lonClose);
        FHE.allow(inZone, msg.sender);
        FHE.allowThis(inZone);
        if (FHE.isInitialized(inZone)) {
            gf.accessCount = FHE.add(gf.accessCount, FHE.asEuint32(1));
            FHE.allowThis(gf.accessCount);
            hasAccess[msg.sender][geofenceId] = true;
        }
        emit AccessAttempt(geofenceId, msg.sender, FHE.isInitialized(inZone));
    }

    function deactivateGeofence(uint256 id) external onlyAdmin { geofences[id].active = false; }

    function allowGeofenceStats(uint256 id, address viewer) external onlyAdmin {
        FHE.allow(geofences[id].accessCount, viewer);
    }
}
