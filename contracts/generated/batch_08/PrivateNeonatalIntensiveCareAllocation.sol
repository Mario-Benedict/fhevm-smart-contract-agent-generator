// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateNeonatalIntensiveCareAllocation
/// @notice Hospital NICU resource allocation with encrypted patient severity scores,
///         bed capacity, nurse ratios, and treatment priority queues — all private.
contract PrivateNeonatalIntensiveCareAllocation is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum AcuityLevel { LEVEL1_CRITICAL, LEVEL2_HIGH, LEVEL3_MODERATE, LEVEL4_STABLE }
    enum BedStatus { OCCUPIED, AVAILABLE, CLEANING, RESERVED, OUT_OF_SERVICE }

    struct NICUBed {
        uint256 bedId;
        BedStatus status;
        euint8 currentAcuityLevel;   // encrypted patient acuity
        euint32 patientAdmissionId;  // encrypted anonymized patient ID
        euint16 hoursOccupied;       // encrypted hours in current stay
        euint8 nurseAssigned;        // encrypted nurse staff ID
        bool isolationRequired;
    }

    struct PatientAdmission {
        euint32 anonymizedPatientId; // encrypted
        euint8 acuityScore;          // encrypted 0-100
        euint16 gestationalAgeWeeks; // encrypted gestational age
        euint32 birthWeightGrams;    // encrypted birth weight
        euint64 estimatedCostUSD;    // encrypted projected treatment cost
        euint32 lengthOfStayHours;   // encrypted estimated LOS
        uint256 admissionTimestamp;
        AcuityLevel acuityLevel;
        bool discharged;
        bool insurancePreauthRequired;
    }

    struct StaffNurse {
        euint8 nurseId;              // encrypted
        euint8 currentPatientCount;  // encrypted current caseload
        euint8 maxPatients;          // encrypted max capacity
        euint32 shiftEndTimestamp;   // encrypted
        bool onDuty;
    }

    mapping(uint256 => NICUBed) private beds;
    mapping(uint256 => PatientAdmission) private admissions;
    mapping(uint256 => StaffNurse) private nurses;
    mapping(uint256 => uint256) private bedToAdmission;
    uint256 public bedCount;
    uint256 public admissionCount;
    uint256 public nurseCount;
    euint64 private _totalRevenueCycle;
    euint32 private _averageLengthOfStay;
    euint8  private _currentOccupancyRate;

    event BedAdded(uint256 indexed bedId);
    event PatientAdmitted(uint256 indexed admissionId, AcuityLevel level);
    event PatientDischarged(uint256 indexed admissionId);
    event BedStatusUpdated(uint256 indexed bedId, BedStatus status);
    event NurseAssigned(uint256 indexed bedId, uint256 nurseId);

    modifier onlyAuthorizedStaff() {
        require(msg.sender == owner(), "Authorized staff only");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRevenueCycle = FHE.asEuint64(0);
        _averageLengthOfStay = FHE.asEuint32(0);
        _currentOccupancyRate = FHE.asEuint8(0);
        FHE.allowThis(_totalRevenueCycle);
        FHE.allowThis(_averageLengthOfStay);
        FHE.allowThis(_currentOccupancyRate);
    }

    function addBed(bool isolationCapable) external onlyOwner returns (uint256 bedId) {
        bedId = bedCount++;
        beds[bedId].bedId = bedId;
        beds[bedId].status = BedStatus.AVAILABLE;
        beds[bedId].currentAcuityLevel = FHE.asEuint8(0);
        beds[bedId].patientAdmissionId = FHE.asEuint32(0);
        beds[bedId].hoursOccupied = FHE.asEuint16(0);
        beds[bedId].nurseAssigned = FHE.asEuint8(0);
        beds[bedId].isolationRequired = isolationCapable;
        FHE.allowThis(beds[bedId].currentAcuityLevel);
        FHE.allowThis(beds[bedId].patientAdmissionId);
        FHE.allowThis(beds[bedId].hoursOccupied);
        FHE.allowThis(beds[bedId].nurseAssigned);
        emit BedAdded(bedId);
    }

    function admitPatient(
        uint256 bedId,
        AcuityLevel level,
        externalEuint8  encAcuity,  bytes calldata aProof,
        externalEuint16 encGestAge, bytes calldata gProof,
        externalEuint32 encWeight,  bytes calldata wProof,
        externalEuint64 encCost,    bytes calldata cProof,
        externalEuint32 encLOS,     bytes calldata losProof
    ) external onlyAuthorizedStaff nonReentrant returns (uint256 admId) {
        require(beds[bedId].status == BedStatus.AVAILABLE, "Bed not available");
        euint8  acuity  = FHE.fromExternal(encAcuity, aProof);
        euint16 gest    = FHE.fromExternal(encGestAge, gProof);
        euint32 weight  = FHE.fromExternal(encWeight, wProof);
        euint64 cost    = FHE.fromExternal(encCost, cProof);
        euint32 los     = FHE.fromExternal(encLOS, losProof);
        admId = admissionCount++;
        euint32 anonId = FHE.asEuint32(uint32(admId + 10000));
        admissions[admId].anonymizedPatientId = anonId;
        admissions[admId].acuityScore = acuity;
        admissions[admId].gestationalAgeWeeks = gest;
        admissions[admId].birthWeightGrams = weight;
        admissions[admId].estimatedCostUSD = cost;
        admissions[admId].lengthOfStayHours = los;
        admissions[admId].admissionTimestamp = block.timestamp;
        admissions[admId].acuityLevel = level;
        admissions[admId].discharged = false;
        admissions[admId].insurancePreauthRequired = level == AcuityLevel.LEVEL1_CRITICAL;
        beds[bedId].status = BedStatus.OCCUPIED;
        beds[bedId].currentAcuityLevel = acuity;
        beds[bedId].patientAdmissionId = anonId;
        bedToAdmission[bedId] = admId;
        _totalRevenueCycle = FHE.add(_totalRevenueCycle, cost);
        FHE.allowThis(admissions[admId].anonymizedPatientId);
        FHE.allowThis(admissions[admId].acuityScore);
        FHE.allowThis(admissions[admId].gestationalAgeWeeks);
        FHE.allowThis(admissions[admId].birthWeightGrams);
        FHE.allowThis(admissions[admId].estimatedCostUSD);
        FHE.allowThis(admissions[admId].lengthOfStayHours);
        FHE.allowThis(beds[bedId].currentAcuityLevel);
        FHE.allowThis(beds[bedId].patientAdmissionId);
        FHE.allowThis(_totalRevenueCycle);
        emit PatientAdmitted(admId, level);
    }

    function dischargePatient(uint256 bedId) external onlyAuthorizedStaff {
        uint256 admId = bedToAdmission[bedId];
        admissions[admId].discharged = true;
        beds[bedId].status = BedStatus.CLEANING;
        beds[bedId].currentAcuityLevel = FHE.asEuint8(0);
        beds[bedId].patientAdmissionId = FHE.asEuint32(0);
        FHE.allowThis(beds[bedId].currentAcuityLevel);
        FHE.allowThis(beds[bedId].patientAdmissionId);
        emit PatientDischarged(admId);
    }

    function markBedAvailable(uint256 bedId) external onlyAuthorizedStaff {
        require(beds[bedId].status == BedStatus.CLEANING, "Not in cleaning");
        beds[bedId].status = BedStatus.AVAILABLE;
        emit BedStatusUpdated(bedId, BedStatus.AVAILABLE);
    }

    function allowClinicalView(uint256 admId, address clinician) external onlyOwner {
        FHE.allow(admissions[admId].acuityScore, clinician);
        FHE.allow(admissions[admId].gestationalAgeWeeks, clinician);
        FHE.allow(admissions[admId].birthWeightGrams, clinician);
        FHE.allow(admissions[admId].estimatedCostUSD, clinician);
    }

    function allowFinancialView(address finance) external onlyOwner {
        FHE.allow(_totalRevenueCycle, finance);
    }
}
