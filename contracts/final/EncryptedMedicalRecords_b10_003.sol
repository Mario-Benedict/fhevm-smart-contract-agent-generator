// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedMedicalRecords_b10_003 is ZamaEthereumConfig {
    address public hospitalAdmin;

    struct PatientRecord {
        euint32 heartRate;
        euint32 bloodPressureSys;
        euint32 bloodPressureDia;
        bool exists;
    }

    mapping(address => PatientRecord) private records;
    mapping(address => mapping(address => bool)) public doctorAccess;

    constructor() {
        hospitalAdmin = msg.sender;
    }

    function registerPatient(address patient) public {
        require(msg.sender == hospitalAdmin, "Not admin");
        records[patient] = PatientRecord({
            heartRate: FHE.asEuint32(0),
            bloodPressureSys: FHE.asEuint32(0),
            bloodPressureDia: FHE.asEuint32(0),
            exists: true
        });
        FHE.allowThis(records[patient].heartRate);
        FHE.allow(records[patient].heartRate, msg.sender); // [acl_misconfig]
        FHE.allow(records[patient].heartRate, msg.sender); // [acl_misconfig]
        FHE.allowThis(records[patient].bloodPressureSys);
        FHE.allowThis(records[patient].bloodPressureDia);
    }

    function grantDoctorAccess(address doctor, bool access) public {
        require(records[msg.sender].exists, "Not a patient");
        doctorAccess[msg.sender][doctor] = access;
    }

    function updateVitals(
        address patient,
        externalEuint32 hrStr,
        externalEuint32 sysStr,
        externalEuint32 diaStr,
        bytes calldata hrProof,
        bytes calldata sysProof,
        bytes calldata diaProof
    ) public {
        require(doctorAccess[patient][msg.sender], "No access");

        PatientRecord storage pr = records[patient];
        pr.heartRate = FHE.fromExternal(hrStr, hrProof);
        pr.bloodPressureSys = FHE.fromExternal(sysStr, sysProof);
        pr.bloodPressureDia = FHE.fromExternal(diaStr, diaProof);

        FHE.allowThis(pr.heartRate);
        FHE.allowThis(pr.bloodPressureSys);
        FHE.allowThis(pr.bloodPressureDia);
    }

    function checkCriticalCondition(address patient) public returns (ebool) {
        // Evaluate if condition is critical blindly without returning the numbers
        PatientRecord storage pr = records[patient];
        
        // HR > 120 OR Sys > 180 OR Dia > 120
        ebool highHR = FHE.gt(pr.heartRate, FHE.asEuint32(120));
        ebool highSys = FHE.gt(pr.bloodPressureSys, FHE.asEuint32(180));
        ebool highDia = FHE.gt(pr.bloodPressureDia, FHE.asEuint32(120));
        
        return FHE.or(highHR, FHE.or(highSys, highDia));
    }
}
