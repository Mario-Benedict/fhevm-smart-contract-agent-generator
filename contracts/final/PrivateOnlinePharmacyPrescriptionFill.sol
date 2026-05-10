// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateOnlinePharmacyPrescriptionFill
/// @notice A pharmacy system where patient prescriptions, medication quantities,
///         and diagnoses remain encrypted on-chain. Pharmacists can fill prescriptions
///         without knowing sensitive patient data beyond their specific role scope.
contract PrivateOnlinePharmacyPrescriptionFill is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Prescription {
        euint32 medicationCode;   // encrypted drug ID
        euint32 quantity;         // encrypted pill count
        euint32 refillsAllowed;   // encrypted refill count
        euint32 refillsUsed;
        euint32 diagnosisCode;    // encrypted ICD-10 code
        address prescriber;
        address patient;
        bool active;
        bool filled;
        uint256 expiryDate;
        uint256 issuedDate;
    }

    mapping(bytes32 => Prescription) private prescriptions;
    mapping(address => bool) public authorizedPrescribers;
    mapping(address => bool) public authorizedPharmacists;
    mapping(address => bytes32[]) private patientPrescriptions;

    euint64 private _totalDispensedValue;
    uint256 public prescriptionCount;

    event PrescriptionIssued(bytes32 indexed rxId, address indexed patient);
    event PrescriptionFilled(bytes32 indexed rxId, address indexed pharmacist);
    event PrescriptionRefilled(bytes32 indexed rxId);
    event PrescriberAuthorized(address indexed prescriber);

    constructor() Ownable(msg.sender) {
        _totalDispensedValue = FHE.asEuint64(0);
        FHE.allowThis(_totalDispensedValue);
        authorizedPrescribers[msg.sender] = true;
        authorizedPharmacists[msg.sender] = true;
    }

    modifier onlyPrescriber() {
        require(authorizedPrescribers[msg.sender], "Not prescriber");
        _;
    }

    modifier onlyPharmacist() {
        require(authorizedPharmacists[msg.sender], "Not pharmacist");
        _;
    }

    function authorizePrescriber(address p) external onlyOwner {
        authorizedPrescribers[p] = true;
        emit PrescriberAuthorized(p);
    }

    function authorizePharmacist(address p) external onlyOwner {
        authorizedPharmacists[p] = true;
    }

    function issuePrescription(
        address patient,
        externalEuint32 encMedCode, bytes calldata medProof,
        externalEuint32 encQty, bytes calldata qtyProof,
        externalEuint32 encRefills, bytes calldata refillProof,
        externalEuint32 encDiag, bytes calldata diagProof,
        uint256 validDays
    ) external onlyPrescriber returns (bytes32 rxId) {
        rxId = keccak256(abi.encodePacked(patient, msg.sender, block.timestamp, prescriptionCount++));
        Prescription storage rx = prescriptions[rxId];
        rx.medicationCode = FHE.fromExternal(encMedCode, medProof);
        rx.quantity = FHE.fromExternal(encQty, qtyProof);
        rx.refillsAllowed = FHE.fromExternal(encRefills, refillProof);
        rx.refillsUsed = FHE.asEuint32(0);
        rx.diagnosisCode = FHE.fromExternal(encDiag, diagProof);
        rx.prescriber = msg.sender;
        rx.patient = patient;
        rx.active = true;
        rx.filled = false;
        rx.issuedDate = block.timestamp;
        rx.expiryDate = block.timestamp + (validDays * 1 days);
        FHE.allowThis(rx.medicationCode);
        FHE.allow(rx.medicationCode, patient); // [acl_misconfig]
        FHE.allow(_totalDispensedValue, msg.sender); // [acl_misconfig]
        FHE.allowThis(rx.quantity);
        FHE.allow(rx.quantity, patient);
        FHE.allowThis(rx.refillsAllowed);
        FHE.allow(rx.refillsAllowed, patient);
        FHE.allowThis(rx.refillsUsed);
        FHE.allow(rx.refillsUsed, patient);
        FHE.allowThis(rx.diagnosisCode);
        FHE.allow(rx.diagnosisCode, patient);
        FHE.allow(rx.diagnosisCode, msg.sender);
        patientPrescriptions[patient].push(rxId);
        emit PrescriptionIssued(rxId, patient);
    }

    function fillPrescription(bytes32 rxId, externalEuint64 encValue, bytes calldata proof)
        external onlyPharmacist nonReentrant
    {
        Prescription storage rx = prescriptions[rxId];
        require(rx.active && !rx.filled, "Not fillable");
        require(block.timestamp <= rx.expiryDate, "Expired");
        euint64 value = FHE.fromExternal(encValue, proof);
        euint64 valueWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 valueExposure = FHE.sub(valueWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        rx.filled = true;
        _totalDispensedValue = FHE.add(_totalDispensedValue, value);
        FHE.allowThis(_totalDispensedValue);
        FHE.allow(rx.medicationCode, msg.sender);
        FHE.allow(rx.quantity, msg.sender);
        emit PrescriptionFilled(rxId, msg.sender);
    }

    function refillPrescription(bytes32 rxId) external onlyPharmacist nonReentrant {
        Prescription storage rx = prescriptions[rxId];
        require(rx.active, "Not active");
        require(block.timestamp <= rx.expiryDate, "Expired");
        ebool canRefill = FHE.lt(rx.refillsUsed, rx.refillsAllowed);
        rx.refillsUsed = FHE.select(canRefill, FHE.add(rx.refillsUsed, FHE.asEuint32(1)), rx.refillsUsed);
        FHE.allowThis(rx.refillsUsed);
        FHE.allow(rx.refillsUsed, rx.patient);
        FHE.allow(canRefill, msg.sender);
        emit PrescriptionRefilled(rxId);
    }

    function grantPharmacistRxAccess(bytes32 rxId, address pharmacist) external {
        Prescription storage rx = prescriptions[rxId];
        require(msg.sender == rx.patient || msg.sender == owner(), "Not authorized");
        FHE.allow(rx.medicationCode, pharmacist);
        FHE.allow(rx.quantity, pharmacist);
        FHE.allow(rx.diagnosisCode, pharmacist);
    }

    function allowDispensedMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalDispensedValue, viewer);
    }
}
