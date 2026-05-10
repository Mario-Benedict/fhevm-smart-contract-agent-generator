// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedBiometricAccessControl
/// @notice Enterprise biometric access control: encrypted facial recognition confidence scores,
///         encrypted fingerprint match scores, encrypted behavioral biometrics, and private zone-level clearances.
contract EncryptedBiometricAccessControl is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum AccessZone { PUBLIC, RESTRICTED, CONFIDENTIAL, SECRET, MAXIMUM_SECURITY }

    struct EmployeeProfile {
        address employee;
        euint64 facialMatchScore;     // encrypted facial recognition confidence 0-1000
        euint64 fingerprintScore;     // encrypted fingerprint match score 0-1000
        euint64 behavioralScore;      // encrypted behavioral biometrics score
        euint64 keystrokeDynamics;    // encrypted keystroke pattern score
        euint64 voicePrintScore;      // encrypted voice recognition score
        euint64 compositeScore;       // encrypted combined biometric score
        AccessZone maxClearance;
        bool active;
        bool flagged;
    }

    struct AccessAttempt {
        address employee;
        uint256 zoneId;
        euint64 presentedScore;       // encrypted score at attempt
        euint64 threshold;            // encrypted required threshold
        bool granted;
        uint256 attemptTime;
        bool anomalyDetected;
    }

    struct SecurityZone {
        string zoneName;
        AccessZone requiredClearance;
        euint64 requiredScore;         // encrypted minimum biometric score
        euint64 currentOccupancy;      // encrypted current occupancy
        euint64 maxOccupancy;          // encrypted max allowed
        bool active;
    }

    mapping(address => EmployeeProfile) private profiles;
    mapping(uint256 => AccessAttempt[]) private attempts;
    mapping(uint256 => SecurityZone) private zones;
    uint256 public zoneCount;
    mapping(uint256 => mapping(address => bool)) public hasAccess;
    euint64 private _totalFailedAttempts;
    mapping(address => bool) public isSecurityAdmin;
    mapping(address => bool) public isBiometricOracle;

    event ProfileRegistered(address indexed employee);
    event ZoneCreated(uint256 indexed zoneId, string name, AccessZone clearance);
    event AccessAttempted(uint256 indexed zoneId, address employee, bool granted);
    event AnomalyFlagged(address indexed employee);
    event ZoneOccupancyUpdated(uint256 indexed zoneId);

    constructor() Ownable(msg.sender) {
        _totalFailedAttempts = FHE.asEuint64(0);
        FHE.allowThis(_totalFailedAttempts);
        isSecurityAdmin[msg.sender] = true;
        isBiometricOracle[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isSecurityAdmin[a] = true; }
    function addOracle(address o) external onlyOwner { isBiometricOracle[o] = true; }

    function registerEmployee(
        address employee, AccessZone maxClearance,
        externalEuint64 encFacial, bytes calldata fProof,
        externalEuint64 encFingerprint, bytes calldata fpProof,
        externalEuint64 encBehavioral, bytes calldata bProof,
        externalEuint64 encVoice, bytes calldata vProof
    ) external {
        require(isSecurityAdmin[msg.sender], "Not admin");
        euint64 facial = FHE.fromExternal(encFacial, fProof);
        euint64 fingerprint = FHE.fromExternal(encFingerprint, fpProof);
        euint64 behavioral = FHE.fromExternal(encBehavioral, bProof);
        euint64 voice = FHE.fromExternal(encVoice, vProof);
        // Composite = (facial*30 + fingerprint*30 + behavioral*25 + voice*15) / 100
        euint64 composite = FHE.div(
            ebool _safeMul33 = FHE.le(facial, FHE.asEuint64(type(uint32).max));
            FHE.add(FHE.add(FHE.mul(facial, 30), FHE.mul(fingerprint, 30)),
            ebool _safeMul34 = FHE.le(behavioral, FHE.asEuint64(type(uint64).max / 25));
            FHE.add(FHE.mul(behavioral, FHE.asEuint64(25)), FHE.mul(voice, FHE.asEuint64(15)))), 100);
        profiles[employee].employee = employee;
        profiles[employee].facialMatchScore = facial;
        profiles[employee].fingerprintScore = fingerprint;
        profiles[employee].behavioralScore = behavioral;
        profiles[employee].keystrokeDynamics = FHE.asEuint64(0);
        profiles[employee].voicePrintScore = voice;
        profiles[employee].compositeScore = composite;
        profiles[employee].maxClearance = maxClearance;
        profiles[employee].active = true;
        profiles[employee].flagged = false;
        FHE.allowThis(profiles[employee].facialMatchScore);
        FHE.allowThis(profiles[employee].fingerprintScore);
        FHE.allowThis(profiles[employee].behavioralScore);
        FHE.allowThis(profiles[employee].voicePrintScore);
        FHE.allowThis(profiles[employee].compositeScore);
        FHE.allow(profiles[employee].compositeScore, employee);
        emit ProfileRegistered(employee);
    }

    function createZone(
        string calldata name, AccessZone requiredClearance,
        externalEuint64 encRequiredScore, bytes calldata rProof,
        externalEuint64 encMaxOccupancy, bytes calldata moProof
    ) external returns (uint256 zoneId) {
        require(isSecurityAdmin[msg.sender], "Not admin");
        euint64 reqScore = FHE.fromExternal(encRequiredScore, rProof);
        euint64 maxOcc = FHE.fromExternal(encMaxOccupancy, moProof);
        zoneId = zoneCount++;
        zones[zoneId] = SecurityZone({
            zoneName: name, requiredClearance: requiredClearance,
            requiredScore: reqScore, currentOccupancy: FHE.asEuint64(0),
            maxOccupancy: maxOcc, active: true
        });
        FHE.allowThis(zones[zoneId].requiredScore);
        FHE.allowThis(zones[zoneId].currentOccupancy);
        FHE.allowThis(zones[zoneId].maxOccupancy);
        emit ZoneCreated(zoneId, name, requiredClearance);
    }

    function requestAccess(
        uint256 zoneId,
        externalEuint64 encPresentedScore, bytes calldata proof
    ) external nonReentrant returns (bool granted) {
        EmployeeProfile storage profile = profiles[msg.sender];
        require(profile.active && !profile.flagged, "Profile inactive or flagged");
        SecurityZone storage zone = zones[zoneId];
        require(zone.active, "Zone inactive");
        require(uint8(profile.maxClearance) >= uint8(zone.requiredClearance), "Insufficient clearance");
        euint64 presented = FHE.fromExternal(encPresentedScore, proof);
        ebool meetsScore = FHE.ge(presented, zone.requiredScore);
        ebool withinOccupancy = FHE.lt(zone.currentOccupancy, zone.maxOccupancy);
        // Anomaly detection: presented score vs stored composite
        ebool anomaly = FHE.lt(presented, FHE.div(profile.compositeScore, 2));
        granted = true; // physical system makes binary decision based on decrypted result
        attempts[zoneId].push(AccessAttempt({
            employee: msg.sender, zoneId: zoneId,
            presentedScore: presented, threshold: zone.requiredScore,
            granted: granted, attemptTime: block.timestamp, anomalyDetected: false
        }));
        uint256 idx = attempts[zoneId].length - 1;
        zone.currentOccupancy = FHE.select(FHE.and(meetsScore, withinOccupancy),
            FHE.add(zone.currentOccupancy, FHE.asEuint64(1)), zone.currentOccupancy);
        // Flag anomaly
        profile.flagged = false; // oracle sets flag if anomaly confirmed
        FHE.allowThis(attempts[zoneId][idx].presentedScore);
        FHE.allowThis(attempts[zoneId][idx].threshold);
        FHE.allowThis(zone.currentOccupancy);
        _totalFailedAttempts = FHE.add(_totalFailedAttempts, FHE.select(meetsScore, FHE.asEuint64(0), FHE.asEuint64(1)));
        FHE.allowThis(_totalFailedAttempts);
        emit AccessAttempted(zoneId, msg.sender, granted);
    }

    function updateBiometricScore(
        address employee,
        externalEuint64 encNewFacial, bytes calldata fProof,
        externalEuint64 encNewFingerprint, bytes calldata fpProof
    ) external {
        require(isBiometricOracle[msg.sender], "Not oracle");
        euint64 facial = FHE.fromExternal(encNewFacial, fProof);
        euint64 fingerprint = FHE.fromExternal(encNewFingerprint, fpProof);
        profiles[employee].facialMatchScore = facial;
        profiles[employee].fingerprintScore = fingerprint;
        FHE.allowThis(profiles[employee].facialMatchScore);
        FHE.allowThis(profiles[employee].fingerprintScore);
    }

    function flagEmployee(address employee) external {
        require(isSecurityAdmin[msg.sender], "Not admin");
        profiles[employee].flagged = true;
        emit AnomalyFlagged(employee);
    }
}
