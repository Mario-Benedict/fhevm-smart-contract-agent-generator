// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateNeonatalICUBedAllocation
/// @notice Encrypted NICU bed capacity management: confidential acuity scores,
///         transport priority queuing, insurance pre-authorization amounts,
///         and encrypted family financial counseling obligations.
contract PrivateNeonatalICUBedAllocation is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum AcuityLevel { LEVEL_I_BASIC, LEVEL_II_SPECIAL_CARE, LEVEL_III_INTENSIVE, LEVEL_IV_REGIONAL }
    enum TransferStatus { LOCAL, TRANSFERRED_IN, TRANSFERRED_OUT, PENDING_TRANSPORT }
    enum InsuranceType { PRIVATE, MEDICAID, SELF_PAY, MILITARY_TRICARE, UNCOMPENSATED }

    struct NeonatalPatient {
        bytes32 patientToken;         // anonymized patient token
        AcuityLevel acuityLevel;
        TransferStatus transferStatus;
        InsuranceType insuranceType;
        euint32 gestationalAgeWeeks;  // encrypted gestational age
        euint32 birthWeightGrams;     // encrypted birth weight
        euint64 acuityScore;          // encrypted clinical acuity score (0-100)
        euint64 dailyCostUSD;         // encrypted daily NICU cost
        euint64 totalAccruedCostUSD;  // encrypted running cost
        euint64 insuranceCoveredUSD;  // encrypted insurance authorization
        euint64 familyLiabilityUSD;   // encrypted out-of-pocket family cost
        euint64 transportCostUSD;     // encrypted transport cost if transferred
        uint256 admittedAt;
        uint256 dischargedAt;
        bool active;
        bool financialCounselingDone;
    }

    struct BedCapacity {
        euint16 totalBeds;            // encrypted total bed count
        euint16 occupiedBeds;         // encrypted current occupancy
        euint16 reservedBeds;         // encrypted beds reserved for transfers
        euint64 dailyRevenueCap;      // encrypted max daily revenue
        euint64 uncompensatedCare;    // encrypted uncompensated care accrued
        euint64 disproportionateShareAmt; // encrypted DSH payment eligibility
    }

    mapping(bytes32 => NeonatalPatient) private patients;
    mapping(address => bool) public authorizedClinician;
    mapping(address => bool) public authorizedFinancialCounselor;
    BedCapacity private capacity;

    euint64 private _totalRevenue30Days;      // encrypted 30-day rolling revenue
    euint64 private _totalUncompensatedCare;  // encrypted total charity care
    euint64 private _qualityBonusAccrued;     // encrypted quality incentive payments

    event PatientAdmitted(bytes32 indexed patientToken, AcuityLevel level);
    event AcuityUpdated(bytes32 indexed patientToken);
    event TransportArranged(bytes32 indexed patientToken, TransferStatus status);
    event InsuranceAuthorized(bytes32 indexed patientToken);
    event PatientDischarged(bytes32 indexed patientToken);
    event FinancialCounselingCompleted(bytes32 indexed patientToken);

    constructor(
        externalEuint16 encTotalBeds, bytes memory tbProof,
        externalEuint16 encReservedBeds, bytes memory rbProof
    ) Ownable(msg.sender) {
        euint16 totalBeds = FHE.fromExternal(encTotalBeds, tbProof);
        euint16 reservedBeds = FHE.fromExternal(encReservedBeds, rbProof);
        capacity = BedCapacity({
            totalBeds: totalBeds,
            occupiedBeds: FHE.asEuint16(0),
            reservedBeds: reservedBeds,
            dailyRevenueCap: FHE.asEuint64(0),
            uncompensatedCare: FHE.asEuint64(0),
            disproportionateShareAmt: FHE.asEuint64(0)
        });
        _totalRevenue30Days = FHE.asEuint64(0);
        _totalUncompensatedCare = FHE.asEuint64(0);
        _qualityBonusAccrued = FHE.asEuint64(0);
        FHE.allowThis(totalBeds);
        FHE.allowThis(reservedBeds);
        FHE.allowThis(capacity.occupiedBeds);
        FHE.allowThis(capacity.dailyRevenueCap);
        FHE.allowThis(capacity.uncompensatedCare);
        FHE.allowThis(capacity.disproportionateShareAmt);
        FHE.allowThis(_totalRevenue30Days);
        FHE.allowThis(_totalUncompensatedCare);
        FHE.allowThis(_qualityBonusAccrued);
    }

    modifier onlyClinician() {
        require(authorizedClinician[msg.sender], "Not authorized clinician");
        _;
    }

    function grantClinicianAccess(address clinician) external onlyOwner {
        authorizedClinician[clinician] = true;
    }

    function grantCounselorAccess(address counselor) external onlyOwner {
        authorizedFinancialCounselor[counselor] = true;
    }

    function admitPatient(
        bytes32 patientToken,
        AcuityLevel level,
        InsuranceType insuranceType,
        externalEuint32 encGestationalAge, bytes calldata gaProof,
        externalEuint32 encBirthWeight, bytes calldata bwProof,
        externalEuint64 encAcuityScore, bytes calldata asProof,
        externalEuint64 encDailyCost, bytes calldata dcProof
    ) external onlyClinician nonReentrant {
        require(!patients[patientToken].active, "Already admitted");

        euint32 gestAge = FHE.fromExternal(encGestationalAge, gaProof);
        euint32 birthWeight = FHE.fromExternal(encBirthWeight, bwProof);
        euint64 acuityScore = FHE.fromExternal(encAcuityScore, asProof);
        euint64 dailyCost = FHE.fromExternal(encDailyCost, dcProof);

        NeonatalPatient storage _s0 = patients[patientToken];
        _s0.patientToken = patientToken;
        _s0.acuityLevel = level;
        _s0.transferStatus = TransferStatus.LOCAL;
        _s0.insuranceType = insuranceType;
        _s0.gestationalAgeWeeks = gestAge;
        _s0.birthWeightGrams = birthWeight;
        _s0.acuityScore = acuityScore;
        _s0.dailyCostUSD = dailyCost;
        _s0.totalAccruedCostUSD = FHE.asEuint64(0);
        _s0.insuranceCoveredUSD = FHE.asEuint64(0);
        _s0.familyLiabilityUSD = FHE.asEuint64(0);
        _s0.transportCostUSD = FHE.asEuint64(0);
        _s0.admittedAt = block.timestamp;
        _s0.dischargedAt = 0;
        _s0.active = true;
        _s0.financialCounselingDone = false;

        capacity.occupiedBeds = FHE.add(capacity.occupiedBeds, FHE.asEuint16(1));

        FHE.allowThis(gestAge);
        FHE.allow(gestAge, msg.sender);
        FHE.allowThis(birthWeight);
        FHE.allow(birthWeight, msg.sender);
        FHE.allowThis(acuityScore);
        FHE.allow(acuityScore, msg.sender);
        FHE.allowThis(dailyCost);
        FHE.allow(dailyCost, msg.sender);
        FHE.allowThis(patients[patientToken].totalAccruedCostUSD);
        FHE.allowThis(patients[patientToken].insuranceCoveredUSD);
        FHE.allowThis(patients[patientToken].familyLiabilityUSD);
        FHE.allowThis(patients[patientToken].transportCostUSD);
        FHE.allowThis(capacity.occupiedBeds);

        emit PatientAdmitted(patientToken, level);
    }

    function updateAcuityAndCost(
        bytes32 patientToken,
        externalEuint64 encNewScore, bytes calldata nsProof,
        externalEuint64 encDaysElapsed, bytes calldata deProof
    ) external onlyClinician {
        NeonatalPatient storage p = patients[patientToken];
        require(p.active, "Not active");
        euint64 newScore = FHE.fromExternal(encNewScore, nsProof);
        euint64 daysElapsed = FHE.fromExternal(encDaysElapsed, deProof);
        p.acuityScore = newScore;
        euint64 additionalCost = FHE.mul(p.dailyCostUSD, daysElapsed);
        p.totalAccruedCostUSD = FHE.add(p.totalAccruedCostUSD, additionalCost);
        _totalRevenue30Days = FHE.add(_totalRevenue30Days, additionalCost);
        FHE.allowThis(p.acuityScore);
        FHE.allow(p.acuityScore, msg.sender);
        FHE.allowThis(p.totalAccruedCostUSD);
        FHE.allow(p.totalAccruedCostUSD, msg.sender);
        FHE.allowThis(_totalRevenue30Days);
        emit AcuityUpdated(patientToken);
    }

    function recordInsuranceAuthorization(
        bytes32 patientToken,
        externalEuint64 encAuthorizedAmt, bytes calldata aaProof
    ) external {
        require(authorizedClinician[msg.sender] || msg.sender == owner(), "Not authorized");
        NeonatalPatient storage p = patients[patientToken];
        require(p.active, "Not active");
        euint64 authorizedAmt = FHE.fromExternal(encAuthorizedAmt, aaProof);
        p.insuranceCoveredUSD = authorizedAmt;
        // Family liability = total cost - insurance coverage
        ebool costExceedsCoverage = FHE.gt(p.totalAccruedCostUSD, authorizedAmt);
        p.familyLiabilityUSD = FHE.select(costExceedsCoverage,
            FHE.sub(p.totalAccruedCostUSD, authorizedAmt),
            FHE.asEuint64(0));
        // If self-pay or uncompensated, track for DSH
        if (p.insuranceType == InsuranceType.SELF_PAY || p.insuranceType == InsuranceType.UNCOMPENSATED) {
            _totalUncompensatedCare = FHE.add(_totalUncompensatedCare, p.totalAccruedCostUSD);
            capacity.uncompensatedCare = FHE.add(capacity.uncompensatedCare, p.totalAccruedCostUSD);
            FHE.allowThis(capacity.uncompensatedCare);
            FHE.allowThis(_totalUncompensatedCare);
        }
        FHE.allowThis(authorizedAmt);
        FHE.allow(authorizedAmt, msg.sender);
        FHE.allowThis(p.familyLiabilityUSD);
        emit InsuranceAuthorized(patientToken);
    }

    function conductFinancialCounseling(
        bytes32 patientToken
    ) external {
        require(authorizedFinancialCounselor[msg.sender], "Not counselor");
        NeonatalPatient storage p = patients[patientToken];
        require(p.active, "Not active");
        p.financialCounselingDone = true;
        FHE.allow(p.familyLiabilityUSD, msg.sender);
        FHE.allow(p.insuranceCoveredUSD, msg.sender);
        FHE.allow(p.totalAccruedCostUSD, msg.sender);
        emit FinancialCounselingCompleted(patientToken);
    }

    function dischargePatient(bytes32 patientToken) external onlyClinician {
        NeonatalPatient storage p = patients[patientToken];
        require(p.active, "Not active");
        p.active = false;
        p.dischargedAt = block.timestamp;
        capacity.occupiedBeds = FHE.sub(capacity.occupiedBeds, FHE.asEuint16(1));
        FHE.allowThis(capacity.occupiedBeds);
        FHE.allowTransient(p.totalAccruedCostUSD, msg.sender);
        emit PatientDischarged(patientToken);
    }

    function allowCapacityView(address viewer) external onlyOwner {
        FHE.allow(capacity.totalBeds, viewer);
        FHE.allow(capacity.occupiedBeds, viewer);
        FHE.allow(capacity.reservedBeds, viewer);
        FHE.allow(capacity.uncompensatedCare, viewer);
        FHE.allow(_totalRevenue30Days, viewer);
        FHE.allow(_totalUncompensatedCare, viewer);
    }
}
