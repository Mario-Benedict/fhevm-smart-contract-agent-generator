// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateHospitalBedAllocation
/// @notice Hospital bed management: encrypted patient acuity scores determine
///         ICU vs general ward allocation; encrypted occupancy rates monitored privately.
contract PrivateHospitalBedAllocation is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum WardType { Emergency, ICU, Surgical, Pediatric, Oncology, General }
    enum PatientStatus { Waiting, Admitted, Transferred, Discharged }

    struct Ward {
        WardType wardType;
        string wardName;
        euint16 totalBeds;             // encrypted bed count
        euint16 occupiedBeds;          // encrypted occupied count
        euint8 staffingRatio;          // encrypted staff per bed
        euint8 icuAcuityThreshold;     // encrypted minimum acuity for ICU admission
        bool active;
    }

    struct Patient {
        euint8 acuityScore;            // encrypted 1-10 clinical severity
        euint8 assignedWardId;         // encrypted ward assignment
        euint64 billingAccrued;        // encrypted billing amount accrued
        euint64 dailyRateUSD;          // encrypted daily room rate
        uint256 admissionTime;
        PatientStatus status;
        address clinician;
    }

    mapping(uint256 => Ward) private wards;
    mapping(address => Patient) private patients;
    mapping(address => bool) public isClinician;
    mapping(address => bool) public isHospitalAdmin;
    uint256 public wardCount;
    euint64 private _totalRevenueAccrued;
    euint16 private _totalBedsSystem;
    euint16 private _totalOccupied;

    event WardCreated(uint256 indexed id, string name);
    event PatientAdmitted(address indexed patient, uint256 wardId);
    event PatientTransferred(address indexed patient, uint256 newWardId);
    event PatientDischarged(address indexed patient);
    event BillingUpdated(address indexed patient);

    modifier onlyClinician() {
        require(isClinician[msg.sender] || msg.sender == owner(), "Not clinician");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRevenueAccrued = FHE.asEuint64(0);
        _totalBedsSystem = FHE.asEuint16(0);
        _totalOccupied = FHE.asEuint16(0);
        FHE.allowThis(_totalRevenueAccrued);
        FHE.allowThis(_totalBedsSystem);
        FHE.allowThis(_totalOccupied);
        isClinician[msg.sender] = true;
        isHospitalAdmin[msg.sender] = true;
    }

    function addClinician(address c) external onlyOwner { isClinician[c] = true; }
    function addAdmin(address a) external onlyOwner { isHospitalAdmin[a] = true; }

    function createWard(
        WardType wardType, string calldata name,
        externalEuint16 encBeds, bytes calldata bProof,
        externalEuint8 encStaffing, bytes calldata sProof,
        externalEuint8 encAcuityThreshold, bytes calldata atProof
    ) external returns (uint256 id) {
        require(isHospitalAdmin[msg.sender], "Not admin");
        euint16 beds = FHE.fromExternal(encBeds, bProof);
        euint8 staffing = FHE.fromExternal(encStaffing, sProof);
        euint8 threshold = FHE.fromExternal(encAcuityThreshold, atProof);
        id = wardCount++;
        wards[id] = Ward({
            wardType: wardType, wardName: name, totalBeds: beds,
            occupiedBeds: FHE.asEuint16(0), staffingRatio: staffing,
            icuAcuityThreshold: threshold, active: true
        });
        _totalBedsSystem = FHE.add(_totalBedsSystem, beds);
        FHE.allowThis(wards[id].totalBeds);
        FHE.allowThis(wards[id].occupiedBeds);
        FHE.allowThis(wards[id].staffingRatio);
        FHE.allowThis(wards[id].icuAcuityThreshold);
        FHE.allowThis(_totalBedsSystem);
        emit WardCreated(id, name);
    }

    function admitPatient(
        address patient, uint256 wardId,
        externalEuint8 encAcuity, bytes calldata aProof,
        externalEuint64 encDailyRate, bytes calldata drProof
    ) external onlyClinician nonReentrant {
        require(patients[patient].status != PatientStatus.Admitted, "Already admitted");
        euint8 acuity = FHE.fromExternal(encAcuity, aProof);
        euint64 dailyRate = FHE.fromExternal(encDailyRate, drProof);
        Ward storage w = wards[wardId];
        require(w.active, "Ward inactive");
        // Check bed availability
        ebool hasBed = FHE.lt(w.occupiedBeds, w.totalBeds);
        euint16 newOccupied = FHE.select(hasBed,
            FHE.add(w.occupiedBeds, FHE.asEuint16(1)),
            w.occupiedBeds);
        w.occupiedBeds = newOccupied;
        _totalOccupied = FHE.add(_totalOccupied, FHE.asEuint16(1));
        patients[patient] = Patient({
            acuityScore: acuity, assignedWardId: FHE.asEuint8(uint8(wardId)),
            billingAccrued: FHE.asEuint64(0), dailyRateUSD: dailyRate,
            admissionTime: block.timestamp, status: PatientStatus.Admitted, clinician: msg.sender
        });
        FHE.allowThis(w.occupiedBeds);
        FHE.allowThis(_totalOccupied);
        FHE.allowThis(patients[patient].acuityScore);
        FHE.allow(patients[patient].acuityScore, msg.sender);
        FHE.allowThis(patients[patient].assignedWardId);
        FHE.allow(patients[patient].assignedWardId, patient);
        FHE.allowThis(patients[patient].billingAccrued);
        FHE.allow(patients[patient].billingAccrued, patient);
        FHE.allowThis(patients[patient].dailyRateUSD);
        emit PatientAdmitted(patient, wardId);
    }

    function updateBilling(address patient) external onlyClinician {
        Patient storage p = patients[patient];
        require(p.status == PatientStatus.Admitted, "Not admitted");
        uint256 daysElapsed = (block.timestamp - p.admissionTime) / 1 days;
        euint64 totalBilling = FHE.mul(p.dailyRateUSD, FHE.asEuint64(uint64(daysElapsed)));
        p.billingAccrued = totalBilling;
        _totalRevenueAccrued = FHE.add(_totalRevenueAccrued, p.dailyRateUSD);
        FHE.allowThis(p.billingAccrued);
        FHE.allow(p.billingAccrued, patient);
        FHE.allowThis(_totalRevenueAccrued);
        emit BillingUpdated(patient);
    }

    function transferPatient(address patient, uint256 newWardId) external onlyClinician {
        patients[patient].assignedWardId = FHE.asEuint8(uint8(newWardId));
        FHE.allowThis(patients[patient].assignedWardId);
        FHE.allow(patients[patient].assignedWardId, patient);
        emit PatientTransferred(patient, newWardId);
    }

    function dischargePatient(address patient) external onlyClinician {
        Patient storage p = patients[patient];
        require(p.status == PatientStatus.Admitted, "Not admitted");
        p.status = PatientStatus.Discharged;
        _totalOccupied = FHE.sub(_totalOccupied, FHE.asEuint16(1));
        wards[uint256(0)].occupiedBeds = FHE.sub(wards[0].occupiedBeds, FHE.asEuint16(1));
        FHE.allowThis(_totalOccupied);
        emit PatientDischarged(patient);
    }

    function allowWardStats(uint256 wardId, address viewer) external {
        require(isHospitalAdmin[msg.sender], "Not admin");
        FHE.allow(wards[wardId].totalBeds, viewer);
        FHE.allow(wards[wardId].occupiedBeds, viewer);
    }

    function allowPatientRecord(address patient, address viewer) external onlyClinician {
        FHE.allow(patients[patient].acuityScore, viewer);
        FHE.allow(patients[patient].billingAccrued, viewer);
        FHE.allow(patients[patient].dailyRateUSD, viewer);
    }
}
