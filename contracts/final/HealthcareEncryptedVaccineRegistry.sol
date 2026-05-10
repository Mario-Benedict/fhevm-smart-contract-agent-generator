// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title HealthcareEncryptedVaccineRegistry
/// @notice National vaccine registry where vaccination status and patient IDs
///         are encrypted. Health authorities can verify compliance without
///         exposing individual vaccination histories.
contract HealthcareEncryptedVaccineRegistry is ZamaEthereumConfig, Ownable {
    struct VaccineRecord {
        euint8 doseCount;           // encrypted doses received
        euint8 vaccinationStatusBits; // bit flags for different vaccines (encrypted)
        euint32 lastVaccinationDate; // encrypted date (days since epoch)
        euint8 exemptionCode;        // 0=none, 1=medical, 2=religious (encrypted)
        bool registered;
    }

    struct VaccineRequirement {
        string vaccineName;
        euint8 requiredDoses;
        bool mandatory;
    }

    mapping(address => VaccineRecord) private vaccineRecords;
    mapping(uint256 => VaccineRequirement) private requirements;
    uint256 public requirementCount;
    mapping(address => bool) public isAuthorizedProvider;
    mapping(address => mapping(address => bool)) public patientConsent; // patient => authority => consent

    event VaccineRecordCreated(address indexed patient);
    event VaccineAdministered(address indexed patient, address provider, uint256 requirementId);
    event ComplianceVerified(address indexed patient, bool compliant);

    constructor() Ownable(msg.sender) {}

    function authorizeProvider(address p) external onlyOwner { isAuthorizedProvider[p] = true; }

    function grantConsent(address authority) external { patientConsent[msg.sender][authority] = true; }
    function revokeConsent(address authority) external { patientConsent[msg.sender][authority] = false; }

    function addRequirement(string calldata name, externalEuint8 encDoses, bytes calldata proof, bool mandatory) external onlyOwner returns (uint256 id) {
        id = requirementCount++;
        requirements[id].vaccineName = name;
        requirements[id].requiredDoses = FHE.fromExternal(encDoses, proof);
        requirements[id].mandatory = mandatory;
        FHE.allowThis(requirements[id].requiredDoses);
    }

    function initRecord() external {
        require(!vaccineRecords[msg.sender].registered, "Exists");
        vaccineRecords[msg.sender].doseCount = FHE.asEuint8(0);
        vaccineRecords[msg.sender].vaccinationStatusBits = FHE.asEuint8(0);
        vaccineRecords[msg.sender].lastVaccinationDate = FHE.asEuint32(0);
        vaccineRecords[msg.sender].exemptionCode = FHE.asEuint8(0);
        vaccineRecords[msg.sender].registered = true;
        FHE.allowThis(vaccineRecords[msg.sender].doseCount);
        FHE.allow(vaccineRecords[msg.sender].doseCount, msg.sender);
        FHE.allowThis(vaccineRecords[msg.sender].vaccinationStatusBits);
        FHE.allow(vaccineRecords[msg.sender].vaccinationStatusBits, msg.sender);
        FHE.allowThis(vaccineRecords[msg.sender].lastVaccinationDate);
        FHE.allowThis(vaccineRecords[msg.sender].exemptionCode);
        emit VaccineRecordCreated(msg.sender);
    }

    function administerVaccine(
        address patient,
        uint256 requirementId,
        externalEuint8 encDoses, bytes calldata dProof,
        externalEuint32 encDate, bytes calldata dateProof
    ) external {
        require(isAuthorizedProvider[msg.sender], "Not provider");
        require(patientConsent[patient][msg.sender] || owner() == msg.sender, "No consent");
        require(vaccineRecords[patient].registered, "No record");
        VaccineRecord storage vr = vaccineRecords[patient];
        euint8 doses = FHE.fromExternal(encDoses, dProof);
        euint32 date = FHE.fromExternal(encDate, dateProof);
        vr.doseCount = FHE.add(vr.doseCount, doses); // [arithmetic_overflow_underflow]
        ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
        vr.lastVaccinationDate = date;
        FHE.allowThis(vr.doseCount);
        FHE.allow(vr.doseCount, patient);
        FHE.allow(vr.doseCount, msg.sender);
        FHE.allowThis(vr.lastVaccinationDate);
        FHE.allow(vr.lastVaccinationDate, patient);
        emit VaccineAdministered(patient, msg.sender, requirementId);
    }

    function verifyCompliance(address patient, uint256 requirementId) external returns (bool) {
        require(patientConsent[patient][msg.sender] || owner() == msg.sender, "No consent");
        VaccineRecord storage vr = vaccineRecords[patient];
        VaccineRequirement storage req = requirements[requirementId];
        // Check exemption first
        ebool hasExemption = FHE.gt(vr.exemptionCode, FHE.asEuint8(0));
        ebool meetsRequirement = FHE.ge(vr.doseCount, req.requiredDoses);
        ebool compliant = FHE.or(hasExemption, meetsRequirement);
        bool result = FHE.isInitialized(compliant);
        emit ComplianceVerified(patient, result);
        return result;
    }

    function setExemption(address patient, externalEuint8 encCode, bytes calldata proof) external onlyOwner {
        vaccineRecords[patient].exemptionCode = FHE.fromExternal(encCode, proof);
        FHE.allowThis(vaccineRecords[patient].exemptionCode);
        FHE.allow(vaccineRecords[patient].exemptionCode, patient);
    }
}
