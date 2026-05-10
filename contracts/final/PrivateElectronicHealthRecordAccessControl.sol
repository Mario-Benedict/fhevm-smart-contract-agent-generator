// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateElectronicHealthRecordAccessControl
/// @notice Patient-controlled EHR with granular encrypted access permissions.
///         Patients grant time-limited, role-specific access to encrypted health data.
contract PrivateElectronicHealthRecordAccessControl is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum RecordType { LAB_RESULT, PRESCRIPTION, IMAGING, DIAGNOSIS, SURGERY, ALLERGY, IMMUNIZATION }
    enum AccessRole { TREATING_PHYSICIAN, SPECIALIST, PHARMACIST, INSURER, RESEARCHER, EMERGENCY }

    struct HealthRecord {
        euint8  recordType;            // encrypted RecordType enum
        euint32 patientId;             // encrypted patient ID
        euint8  sensitivityLevel;      // encrypted 1-5
        euint64 recordHash;            // encrypted IPFS-like content hash (truncated)
        euint32 providerId;            // encrypted issuing provider
        uint256 createdAt;
        uint256 retentionUntil;
        bool deleted;
    }

    struct AccessGrant {
        euint32 granteeRoleId;         // encrypted role
        euint64 expiryTimestamp;       // encrypted expiry
        euint8  accessLevelBps;        // encrypted access scope
        bool active;
    }

    struct PatientConsent {
        euint8  researchConsentLevel;  // encrypted 0=none, 1=anon, 2=identified
        euint8  emergencyShareFlag;    // encrypted
        euint32 primaryPhysicianId;    // encrypted
        bool globalConsentActive;
    }

    mapping(address => mapping(uint256 => HealthRecord)) private records;
    mapping(address => uint256) private patientRecordCount;
    mapping(address => mapping(address => AccessGrant)) private accessGrants;
    mapping(address => PatientConsent) private consents;
    mapping(address => bool) public isHealthcareProvider;
    mapping(address => bool) public isConsentAuditor;
    euint64 private _totalRecordsCreated;
    euint64 private _totalAccessGrantsActive;

    event RecordCreated(address indexed patient, uint256 recordId);
    event AccessGranted(address indexed patient, address indexed grantee);
    event AccessRevoked(address indexed patient, address indexed grantee);
    event ConsentUpdated(address indexed patient);

    constructor() Ownable(msg.sender) {
        _totalRecordsCreated = FHE.asEuint64(0);
        _totalAccessGrantsActive = FHE.asEuint64(0);
        FHE.allowThis(_totalRecordsCreated);
        FHE.allowThis(_totalAccessGrantsActive);
        isHealthcareProvider[msg.sender] = true;
        isConsentAuditor[msg.sender] = true;
    }

    function addProvider(address p) external onlyOwner { isHealthcareProvider[p] = true; }
    function addAuditor(address a) external onlyOwner { isConsentAuditor[a] = true; }

    function createRecord(
        address patient,
        RecordType rType,
        externalEuint8  encSensitivity, bytes calldata sensProof,
        externalEuint64 encContentHash, bytes calldata hashProof,
        externalEuint32 encProviderId,  bytes calldata provProof,
        uint256 retentionYears
    ) external returns (uint256 recordId) {
        require(isHealthcareProvider[msg.sender], "Not provider");
        euint8  sensitivity = FHE.fromExternal(encSensitivity, sensProof);
        euint64 contentHash = FHE.fromExternal(encContentHash, hashProof);
        euint32 providerId  = FHE.fromExternal(encProviderId, provProof);
        recordId = patientRecordCount[patient]++;
        records[patient][recordId] = HealthRecord({
            recordType: FHE.asEuint8(uint8(rType)),
            patientId: FHE.asEuint32(uint32(uint160(patient) % 1000000)),
            sensitivityLevel: sensitivity,
            recordHash: contentHash,
            providerId: providerId,
            createdAt: block.timestamp,
            retentionUntil: block.timestamp + retentionYears * 365 days,
            deleted: false
        });
        _totalRecordsCreated = FHE.add(_totalRecordsCreated, FHE.asEuint64(1));
        FHE.allowThis(records[patient][recordId].recordType);
        FHE.allow(records[patient][recordId].recordType, patient);
        FHE.allowThis(records[patient][recordId].patientId);
        FHE.allow(records[patient][recordId].patientId, patient);
        FHE.allowThis(records[patient][recordId].sensitivityLevel);
        FHE.allow(records[patient][recordId].sensitivityLevel, patient);
        FHE.allowThis(records[patient][recordId].recordHash);
        FHE.allow(records[patient][recordId].recordHash, patient);
        FHE.allowThis(records[patient][recordId].providerId);
        FHE.allowThis(_totalRecordsCreated);
        emit RecordCreated(patient, recordId);
    }

    function grantAccess(
        address grantee,
        AccessRole role,
        externalEuint64 encExpiry,      bytes calldata expProof,
        externalEuint8  encAccessLevel, bytes calldata alProof
    ) external {
        euint64 expiry     = FHE.fromExternal(encExpiry, expProof);
        euint8  accessLevel= FHE.fromExternal(encAccessLevel, alProof);
        accessGrants[msg.sender][grantee] = AccessGrant({
            granteeRoleId: FHE.asEuint32(uint32(role)),
            expiryTimestamp: expiry,
            accessLevelBps: accessLevel,
            active: true
        });
        _totalAccessGrantsActive = FHE.add(_totalAccessGrantsActive, FHE.asEuint64(1));
        FHE.allowThis(accessGrants[msg.sender][grantee].granteeRoleId);
        FHE.allow(accessGrants[msg.sender][grantee].granteeRoleId, grantee);
        FHE.allowThis(accessGrants[msg.sender][grantee].expiryTimestamp);
        FHE.allow(accessGrants[msg.sender][grantee].expiryTimestamp, grantee);
        FHE.allowThis(accessGrants[msg.sender][grantee].accessLevelBps);
        FHE.allowThis(_totalAccessGrantsActive);
        emit AccessGranted(msg.sender, grantee);
    }

    function revokeAccess(address grantee) external {
        accessGrants[msg.sender][grantee].active = false;
        emit AccessRevoked(msg.sender, grantee);
    }

    function allowRecordToGrantee(address patient, uint256 recordId, address grantee) external {
        require(isHealthcareProvider[msg.sender] || msg.sender == patient, "Unauthorized");
        require(accessGrants[patient][grantee].active, "No active grant");
        FHE.allow(records[patient][recordId].recordHash, grantee);
        FHE.allow(records[patient][recordId].sensitivityLevel, grantee);
    }

    function updateConsent(
        externalEuint8  encResearchLevel, bytes calldata rlProof,
        externalEuint8  encEmergencyFlag, bytes calldata efProof
    ) external {
        euint8 resLevel = FHE.fromExternal(encResearchLevel, rlProof);
        euint8 emer     = FHE.fromExternal(encEmergencyFlag, efProof);
        consents[msg.sender].researchConsentLevel = resLevel;
        consents[msg.sender].emergencyShareFlag = emer;
        consents[msg.sender].globalConsentActive = true;
        FHE.allowThis(consents[msg.sender].researchConsentLevel);
        FHE.allow(consents[msg.sender].researchConsentLevel, msg.sender);
        FHE.allowThis(consents[msg.sender].emergencyShareFlag);
        emit ConsentUpdated(msg.sender);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalRecordsCreated, viewer);
        FHE.allow(_totalAccessGrantsActive, viewer);
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