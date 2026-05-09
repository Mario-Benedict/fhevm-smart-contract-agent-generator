// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title HealthcareEncryptedEHR
/// @notice Electronic Health Records with encrypted diagnoses and treatment history.
///         Only authorized providers can decrypt patient-specific records.
///         Patients control who can access their health data.
contract HealthcareEncryptedEHR is ZamaEthereumConfig, Ownable {
    struct MedicalRecord {
        euint8 bloodType;             // encrypted (0=A+, 1=A-, etc.)
        euint16 bloodPressureSystolic;
        euint16 bloodPressureDiastolic;
        euint8 BMI;                   // encrypted BMI * 10 to avoid floats
        euint8 diabetesRiskScore;
        euint8 cardiacRiskScore;
        euint32 chronicConditionFlags; // encrypted bit flags for conditions
        uint256 lastUpdated;
        bool exists;
    }

    struct Treatment {
        euint16 treatmentCode;        // encrypted ICD code
        euint64 cost;                 // encrypted treatment cost
        uint256 date;
        address provider;
    }

    mapping(address => MedicalRecord) private records;
    mapping(address => Treatment[]) private treatmentHistory;
    mapping(address => mapping(address => bool)) private providerAccess; // patient => provider => allowed
    mapping(address => bool) public isProvider;

    event RecordCreated(address indexed patient);
    event RecordUpdated(address indexed patient);
    event TreatmentAdded(address indexed patient, address provider);
    event AccessGranted(address indexed patient, address provider);
    event AccessRevoked(address indexed patient, address provider);

    constructor() Ownable(msg.sender) {}

    function registerProvider(address p) external onlyOwner { isProvider[p] = true; }

    function grantAccess(address provider) external {
        require(isProvider[provider], "Not provider");
        providerAccess[msg.sender][provider] = true;
        if (records[msg.sender].exists) {
            FHE.allow(records[msg.sender].bloodType, provider);
            FHE.allow(records[msg.sender].bloodPressureSystolic, provider);
            FHE.allow(records[msg.sender].bloodPressureDiastolic, provider);
            FHE.allow(records[msg.sender].BMI, provider);
            FHE.allow(records[msg.sender].diabetesRiskScore, provider);
            FHE.allow(records[msg.sender].cardiacRiskScore, provider);
            FHE.allow(records[msg.sender].chronicConditionFlags, provider);
        }
        emit AccessGranted(msg.sender, provider);
    }

    function revokeAccess(address provider) external {
        providerAccess[msg.sender][provider] = false;
        emit AccessRevoked(msg.sender, provider);
    }

    function createRecord(
        externalEuint8 encBloodType, bytes calldata btProof,
        externalEuint16 encSystolic, bytes calldata sProof,
        externalEuint16 encDiastolic, bytes calldata dProof,
        externalEuint8 encBMI, bytes calldata bProof,
        externalEuint8 encDiabetes, bytes calldata dbProof,
        externalEuint8 encCardiac, bytes calldata cProof
    ) external {
        require(!records[msg.sender].exists, "Record exists");
        MedicalRecord storage r = records[msg.sender];
        r.bloodType = FHE.fromExternal(encBloodType, btProof);
        r.bloodPressureSystolic = FHE.fromExternal(encSystolic, sProof);
        r.bloodPressureDiastolic = FHE.fromExternal(encDiastolic, dProof);
        r.BMI = FHE.fromExternal(encBMI, bProof);
        r.diabetesRiskScore = FHE.fromExternal(encDiabetes, dbProof);
        r.cardiacRiskScore = FHE.fromExternal(encCardiac, cProof);
        r.chronicConditionFlags = FHE.asEuint32(0);
        r.lastUpdated = block.timestamp;
        r.exists = true;
        FHE.allowThis(r.bloodType);
        FHE.allow(r.bloodType, msg.sender);
        FHE.allowThis(r.bloodPressureSystolic);
        FHE.allow(r.bloodPressureSystolic, msg.sender);
        FHE.allowThis(r.bloodPressureDiastolic);
        FHE.allow(r.bloodPressureDiastolic, msg.sender);
        FHE.allowThis(r.BMI);
        FHE.allow(r.BMI, msg.sender);
        FHE.allowThis(r.diabetesRiskScore);
        FHE.allow(r.diabetesRiskScore, msg.sender);
        FHE.allowThis(r.cardiacRiskScore);
        FHE.allow(r.cardiacRiskScore, msg.sender);
        FHE.allowThis(r.chronicConditionFlags);
        emit RecordCreated(msg.sender);
    }

    function updateRiskScores(
        address patient,
        externalEuint8 encDiabetes, bytes calldata dProof,
        externalEuint8 encCardiac, bytes calldata cProof
    ) external {
        require(isProvider[msg.sender] && providerAccess[patient][msg.sender], "No access");
        MedicalRecord storage r = records[patient];
        r.diabetesRiskScore = FHE.fromExternal(encDiabetes, dProof);
        r.cardiacRiskScore = FHE.fromExternal(encCardiac, cProof);
        r.lastUpdated = block.timestamp;
        FHE.allowThis(r.diabetesRiskScore);
        FHE.allow(r.diabetesRiskScore, patient);
        FHE.allow(r.diabetesRiskScore, msg.sender);
        FHE.allowThis(r.cardiacRiskScore);
        FHE.allow(r.cardiacRiskScore, patient);
        FHE.allow(r.cardiacRiskScore, msg.sender);
        emit RecordUpdated(patient);
    }

    function addTreatment(
        address patient,
        externalEuint16 encCode, bytes calldata cProof,
        externalEuint64 encCost, bytes calldata costProof
    ) external {
        require(isProvider[msg.sender] && providerAccess[patient][msg.sender], "No access");
        euint16 code = FHE.fromExternal(encCode, cProof);
        euint64 cost = FHE.fromExternal(encCost, costProof);
        treatmentHistory[patient].push(Treatment({
            treatmentCode: code, cost: cost, date: block.timestamp, provider: msg.sender
        }));
        uint256 lastIdx = treatmentHistory[patient].length - 1;
        FHE.allowThis(treatmentHistory[patient][lastIdx].treatmentCode);
        FHE.allow(treatmentHistory[patient][lastIdx].treatmentCode, patient);
        FHE.allowThis(treatmentHistory[patient][lastIdx].cost);
        FHE.allow(treatmentHistory[patient][lastIdx].cost, patient);
        emit TreatmentAdded(patient, msg.sender);
    }

    function getRecordExists(address patient) external view returns (bool) {
        return records[patient].exists;
    }
}
