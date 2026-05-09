// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MedicalRecordAccess - Encrypted patient medical record with provider-specific access
contract MedicalRecordAccess is ZamaEthereumConfig, AccessControl {
    bytes32 public constant PROVIDER_ROLE = keccak256("PROVIDER_ROLE");
    bytes32 public constant PATIENT_ROLE = keccak256("PATIENT_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    struct MedicalRecord {
        euint8 bloodType;         // 0-7 coded
        euint8 allergyFlags;      // bitmask
        euint16 diagnosisCode;    // ICD-10 numeric
        euint8 medicationCount;
        euint32 lastUpdated;
        bool exists;
    }

    struct AccessGrant {
        address provider;
        uint256 expiresAt;
        bool active;
    }

    mapping(address => MedicalRecord) private records;
    mapping(address => AccessGrant[]) public accessGrants;
    mapping(address => mapping(address => bool)) public hasAccess;

    event RecordCreated(address indexed patient);
    event RecordUpdated(address indexed patient);
    event AccessGranted(address indexed patient, address indexed provider);
    event AccessRevoked(address indexed patient, address indexed provider);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function registerPatient(address patient) external onlyRole(ADMIN_ROLE) {
        _grantRole(PATIENT_ROLE, patient);
    }

    function registerProvider(address provider) external onlyRole(ADMIN_ROLE) {
        _grantRole(PROVIDER_ROLE, provider);
    }

    function createRecord(
        externalEuint8 encBloodType,
        bytes calldata btProof,
        externalEuint8 encAllergyFlags,
        bytes calldata afProof,
        externalEuint16 encDiagnosis,
        bytes calldata dxProof
    ) external onlyRole(PATIENT_ROLE) {
        require(!records[msg.sender].exists, "Record exists");
        MedicalRecord storage r = records[msg.sender];
        r.bloodType = FHE.fromExternal(encBloodType, btProof);
        r.allergyFlags = FHE.fromExternal(encAllergyFlags, afProof);
        r.diagnosisCode = FHE.fromExternal(encDiagnosis, dxProof);
        r.medicationCount = FHE.asEuint8(0);
        r.lastUpdated = FHE.asEuint32(uint32(block.timestamp));
        r.exists = true;
        FHE.allowThis(r.bloodType);
        FHE.allowThis(r.allergyFlags);
        FHE.allowThis(r.diagnosisCode);
        FHE.allowThis(r.medicationCount);
        FHE.allowThis(r.lastUpdated);
        FHE.allow(r.bloodType, msg.sender);
        FHE.allow(r.allergyFlags, msg.sender);
        FHE.allow(r.diagnosisCode, msg.sender);
        emit RecordCreated(msg.sender);
    }

    function grantAccess(address provider, uint256 duration) external onlyRole(PATIENT_ROLE) {
        require(hasRole(PROVIDER_ROLE, provider), "Not a provider");
        hasAccess[msg.sender][provider] = true;
        accessGrants[msg.sender].push(AccessGrant(provider, block.timestamp + duration, true));
        MedicalRecord storage r = records[msg.sender];
        FHE.allow(r.bloodType, provider);
        FHE.allow(r.allergyFlags, provider);
        FHE.allow(r.diagnosisCode, provider);
        FHE.allow(r.medicationCount, provider);
        emit AccessGranted(msg.sender, provider);
    }

    function revokeAccess(address provider) external onlyRole(PATIENT_ROLE) {
        hasAccess[msg.sender][provider] = false;
        emit AccessRevoked(msg.sender, provider);
    }

    function updateDiagnosis(address patient, externalEuint16 encCode, bytes calldata inputProof)
        external
        onlyRole(PROVIDER_ROLE)
    {
        require(hasAccess[patient][msg.sender], "No access");
        records[patient].diagnosisCode = FHE.fromExternal(encCode, inputProof);
        records[patient].lastUpdated = FHE.asEuint32(uint32(block.timestamp));
        FHE.allowThis(records[patient].diagnosisCode);
        FHE.allowThis(records[patient].lastUpdated);
        FHE.allow(records[patient].diagnosisCode, patient);
        FHE.allow(records[patient].diagnosisCode, msg.sender);
        emit RecordUpdated(patient);
    }
}
