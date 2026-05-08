// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedTelemedicineConsultationFee
/// @notice Telemedicine platform: encrypted consultation fees, encrypted patient
///         health insurance reimbursement, and encrypted doctor quality ratings.
contract EncryptedTelemedicineConsultationFee is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ConsultationType { GeneralPractice, Specialist, Mental_Health, Emergency, SecondOpinion }
    enum InsurancePlan { None, BasicHMO, PPO, HighDeductible, Government }

    struct DoctorProfile {
        address doctor;
        string licenseNumber;
        string specialty;
        euint64 standardFeeUSD;        // encrypted consultation fee
        euint32 qualityScore;          // encrypted platform quality rating
        euint32 patientSatisfaction;   // encrypted patient satisfaction score
        euint64 totalEarnedUSD;        // encrypted cumulative earnings
        uint256 consultationsCount;
        bool active;
    }

    struct Consultation {
        address patient;
        address doctor;
        ConsultationType consultType;
        InsurancePlan insurancePlan;
        euint64 grossFeeUSD;           // encrypted full fee
        euint64 insuranceReimbursement; // encrypted insurance portion
        euint64 patientCopayUSD;       // encrypted patient out-of-pocket
        euint32 sessionDurationMins;   // encrypted session length
        euint16 patientRating;         // encrypted patient rating (1-5 scale * 100)
        uint256 sessionDate;
        bool completed;
    }

    mapping(address => DoctorProfile) private doctors;
    mapping(uint256 => Consultation) private consultations;
    mapping(address => bool) public isInsurancePayer;
    mapping(address => bool) public isPlatformAdmin;

    uint256 public consultationCount;
    euint64 private _totalPlatformRevenue;
    euint64 private _totalInsuranceReimbursed;

    event DoctorRegistered(address indexed doctor, string specialty);
    event ConsultationBooked(uint256 indexed id, address patient, address doctor);
    event ConsultationCompleted(uint256 indexed id);
    event DoctorRated(address indexed doctor, uint256 consultationId);

    modifier onlyAdmin() {
        require(isPlatformAdmin[msg.sender] || msg.sender == owner(), "Not admin");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPlatformRevenue = FHE.asEuint64(0);
        _totalInsuranceReimbursed = FHE.asEuint64(0);
        FHE.allowThis(_totalPlatformRevenue);
        FHE.allowThis(_totalInsuranceReimbursed);
        isPlatformAdmin[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isPlatformAdmin[a] = true; }
    function addPayer(address p) external onlyOwner { isInsurancePayer[p] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerDoctor(
        string calldata license, string calldata specialty,
        externalEuint64 encFee, bytes calldata fProof
    ) external whenNotPaused {
        euint64 fee = FHE.fromExternal(encFee, fProof);
        doctors[msg.sender] = DoctorProfile({
            doctor: msg.sender, licenseNumber: license, specialty: specialty,
            standardFeeUSD: fee, qualityScore: FHE.asEuint32(500),
            patientSatisfaction: FHE.asEuint32(0), totalEarnedUSD: FHE.asEuint64(0),
            consultationsCount: 0, active: true
        });
        FHE.allowThis(doctors[msg.sender].standardFeeUSD); FHE.allow(doctors[msg.sender].standardFeeUSD, msg.sender);
        FHE.allowThis(doctors[msg.sender].qualityScore); FHE.allow(doctors[msg.sender].qualityScore, msg.sender);
        FHE.allowThis(doctors[msg.sender].patientSatisfaction); FHE.allow(doctors[msg.sender].patientSatisfaction, msg.sender);
        FHE.allowThis(doctors[msg.sender].totalEarnedUSD); FHE.allow(doctors[msg.sender].totalEarnedUSD, msg.sender);
        emit DoctorRegistered(msg.sender, specialty);
    }

    function bookConsultation(
        address doctor, ConsultationType consultType, InsurancePlan plan,
        externalEuint64 encInsurancePortion, bytes calldata iProof,
        externalEuint32 encDuration, bytes calldata dProof
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        DoctorProfile storage d = doctors[doctor];
        require(d.active, "Doctor not active");
        euint64 insurancePortion = FHE.fromExternal(encInsurancePortion, iProof);
        euint32 duration = FHE.fromExternal(encDuration, dProof);
        euint64 copay = FHE.sub(d.standardFeeUSD, insurancePortion);
        id = consultationCount++;
        consultations[id] = Consultation({
            patient: msg.sender, doctor: doctor, consultType: consultType,
            insurancePlan: plan, grossFeeUSD: d.standardFeeUSD,
            insuranceReimbursement: insurancePortion, patientCopayUSD: copay,
            sessionDurationMins: duration, patientRating: FHE.asEuint16(0),
            sessionDate: block.timestamp, completed: false
        });
        FHE.allowThis(consultations[id].grossFeeUSD); FHE.allow(consultations[id].grossFeeUSD, msg.sender); FHE.allow(consultations[id].grossFeeUSD, doctor);
        FHE.allowThis(consultations[id].insuranceReimbursement); FHE.allow(consultations[id].insuranceReimbursement, msg.sender);
        FHE.allowThis(consultations[id].patientCopayUSD); FHE.allow(consultations[id].patientCopayUSD, msg.sender);
        FHE.allowThis(consultations[id].sessionDurationMins); FHE.allow(consultations[id].sessionDurationMins, doctor);
        FHE.allowThis(consultations[id].patientRating);
        emit ConsultationBooked(id, msg.sender, doctor);
    }

    function completeConsultation(uint256 consultationId) external {
        Consultation storage c = consultations[consultationId];
        require(c.doctor == msg.sender && !c.completed, "Not doctor or already done");
        c.completed = true;
        DoctorProfile storage d = doctors[msg.sender];
        d.totalEarnedUSD = FHE.add(d.totalEarnedUSD, c.grossFeeUSD);
        d.consultationsCount++;
        _totalPlatformRevenue = FHE.add(_totalPlatformRevenue, c.grossFeeUSD);
        _totalInsuranceReimbursed = FHE.add(_totalInsuranceReimbursed, c.insuranceReimbursement);
        FHE.allowThis(d.totalEarnedUSD); FHE.allow(d.totalEarnedUSD, msg.sender);
        FHE.allowThis(_totalPlatformRevenue);
        FHE.allowThis(_totalInsuranceReimbursed);
        emit ConsultationCompleted(consultationId);
    }

    function rateConsultation(uint256 consultationId, externalEuint16 encRating, bytes calldata proof) external {
        Consultation storage c = consultations[consultationId];
        require(c.patient == msg.sender && c.completed, "Not patient or not done");
        c.patientRating = FHE.fromExternal(encRating, proof);
        FHE.allowThis(c.patientRating); FHE.allow(c.patientRating, c.doctor);
        emit DoctorRated(c.doctor, consultationId);
    }

    function updateDoctorQuality(address doctor, externalEuint32 encScore, bytes calldata proof) external onlyAdmin {
        doctors[doctor].qualityScore = FHE.fromExternal(encScore, proof);
        FHE.allowThis(doctors[doctor].qualityScore); FHE.allow(doctors[doctor].qualityScore, doctor);
    }

    function allowPlatformStats(address viewer) external onlyOwner {
        FHE.allow(_totalPlatformRevenue, viewer);
        FHE.allow(_totalInsuranceReimbursed, viewer);
    }
}
