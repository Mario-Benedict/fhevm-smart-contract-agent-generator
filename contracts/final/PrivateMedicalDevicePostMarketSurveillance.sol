// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMedicalDevicePostMarketSurveillance
/// @notice Post-market surveillance for medical devices with encrypted
///         adverse event rates, device failure data, and MDRC (Medical
///         Device Recall Committee) confidential deliberations.
contract PrivateMedicalDevicePostMarketSurveillance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DeviceClass { ClassI, ClassII, ClassIII, InVitroDiagnostic }
    enum EventSeverity { Malfunction, SeriousInjury, Death, NearMiss }
    enum RecallStatus { NoRecall, UnderInvestigation, VoluntaryRecall, MandatoryRecall, Cleared }

    struct MedicalDevice {
        uint256 deviceId;
        string productCode;
        string manufacturerName;
        DeviceClass deviceClass;
        euint32 unitsDistributed;      // encrypted units on market
        euint32 adverseEventCount;     // encrypted total AEs reported
        euint16 adverseEventRateBps;   // encrypted AE rate per 10k units
        euint32 malfunctionCount;      // encrypted malfunctions
        euint32 seriousInjuryCount;    // encrypted serious injuries
        euint32 deathCount;            // encrypted fatalities
        euint64 estimatedPatientRisk;  // encrypted composite risk score
        RecallStatus recallStatus;
        bool active;
    }

    struct AdverseEvent {
        uint256 deviceId;
        EventSeverity severity;
        euint32 patientAge;            // encrypted patient age
        euint8 patientSex;             // encrypted (0=male,1=female,2=unknown)
        euint16 implantDurationMonths; // encrypted time in use
        euint32 deviceUsageCount;      // encrypted total uses before failure
        bool reporterIsPhysician;
        uint256 reportedAt;
        bool adjudicated;
    }

    struct RecallRecord {
        uint256 deviceId;
        RecallStatus recallType;
        euint32 affectedUnits;         // encrypted units recalled
        euint64 estimatedCostUSD;      // encrypted recall cost
        string reasonCode;
        uint256 initiatedAt;
        bool completed;
    }

    mapping(uint256 => MedicalDevice) private devices;
    mapping(uint256 => AdverseEvent[]) private adverseEvents;
    mapping(uint256 => RecallRecord[]) private recalls;
    mapping(address => bool) public isManufacturer;
    mapping(address => bool) public isRegulatoryOfficer;

    uint256 public deviceCount;
    euint64 private _totalAEsReported;
    euint64 private _totalUnitsRecalled;
    euint64 private _totalRecallCostUSD;

    event DeviceRegistered(uint256 indexed deviceId, DeviceClass deviceClass);
    event AdverseEventReported(uint256 indexed deviceId, EventSeverity severity);
    event RecallInitiated(uint256 indexed deviceId, RecallStatus recallType);
    event RecallCompleted(uint256 indexed deviceId);
    event RiskAlertIssued(uint256 indexed deviceId);

    modifier onlyRegulator() {
        require(isRegulatoryOfficer[msg.sender] || msg.sender == owner(), "Not regulatory officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAEsReported = FHE.asEuint64(0);
        _totalUnitsRecalled = FHE.asEuint64(0);
        _totalRecallCostUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalAEsReported);
        FHE.allowThis(_totalUnitsRecalled);
        FHE.allowThis(_totalRecallCostUSD);
        isRegulatoryOfficer[msg.sender] = true;
    }

    function addRegulator(address reg) external onlyOwner { isRegulatoryOfficer[reg] = true; }
    function registerManufacturer(address mfr) external onlyOwner { isManufacturer[mfr] = true; }

    function registerDevice(
        string calldata productCode,
        string calldata manufacturerName,
        DeviceClass deviceClass,
        externalEuint32 encUnitsDistributed, bytes calldata unitsProof
    ) external returns (uint256 deviceId) {
        require(isManufacturer[msg.sender] || isRegulatoryOfficer[msg.sender], "Not authorized");
        deviceId = deviceCount++;
        MedicalDevice storage d = devices[deviceId];
        d.deviceId = deviceId;
        d.productCode = productCode;
        d.manufacturerName = manufacturerName;
        d.deviceClass = deviceClass;
        d.unitsDistributed = FHE.fromExternal(encUnitsDistributed, unitsProof);
        d.adverseEventCount = FHE.asEuint32(0);
        d.adverseEventRateBps = FHE.asEuint16(0);
        d.malfunctionCount = FHE.asEuint32(0);
        d.seriousInjuryCount = FHE.asEuint32(0);
        d.deathCount = FHE.asEuint32(0);
        d.estimatedPatientRisk = FHE.asEuint64(0);
        d.recallStatus = RecallStatus.NoRecall;
        d.active = true;
        FHE.allowThis(d.unitsDistributed); FHE.allow(d.unitsDistributed, msg.sender);
        FHE.allowThis(d.adverseEventCount); FHE.allowThis(d.adverseEventRateBps);
        FHE.allowThis(d.malfunctionCount); FHE.allowThis(d.seriousInjuryCount);
        FHE.allowThis(d.deathCount); FHE.allowThis(d.estimatedPatientRisk);
        emit DeviceRegistered(deviceId, deviceClass);
    }

    function reportAdverseEvent(
        uint256 deviceId,
        EventSeverity severity,
        externalEuint32 encPatientAge, bytes calldata ageProof,
        externalEuint8 encSex, bytes calldata sexProof,
        externalEuint16 encImplantDuration, bytes calldata durProof,
        bool reporterIsPhysician
    ) external nonReentrant {
        MedicalDevice storage d = devices[deviceId];
        require(d.active, "Device not active");

        euint32 patientAge = FHE.fromExternal(encPatientAge, ageProof);



        euint8 sex = FHE.fromExternal(encSex, sexProof);
        euint16 implantDuration = FHE.fromExternal(encImplantDuration, durProof);

        uint256 aeIdx = adverseEvents[deviceId].length;
        adverseEvents[deviceId].push(AdverseEvent({
            deviceId: deviceId,
            severity: severity,
            patientAge: patientAge,
            patientSex: sex,
            implantDurationMonths: implantDuration,
            deviceUsageCount: FHE.asEuint32(0),
            reporterIsPhysician: reporterIsPhysician,
            reportedAt: block.timestamp,
            adjudicated: false
        }));

        d.adverseEventCount = FHE.add(d.adverseEventCount, FHE.asEuint32(1));
        if (severity == EventSeverity.SeriousInjury) {
            d.seriousInjuryCount = FHE.add(d.seriousInjuryCount, FHE.asEuint32(1));
        } else if (severity == EventSeverity.Death) {
            d.deathCount = FHE.add(d.deathCount, FHE.asEuint32(1));
        } else if (severity == EventSeverity.Malfunction) {
            d.malfunctionCount = FHE.add(d.malfunctionCount, FHE.asEuint32(1));
        }

        _totalAEsReported = FHE.add(_totalAEsReported, FHE.asEuint64(1));

        // Update risk score: deaths weighted 100, injuries 10, malfunctions 1
        euint64 riskDelta = severity == EventSeverity.Death ? FHE.asEuint64(100)
            : severity == EventSeverity.SeriousInjury ? FHE.asEuint64(10)
            : FHE.asEuint64(1);
        d.estimatedPatientRisk = FHE.add(d.estimatedPatientRisk, riskDelta);

        FHE.allowThis(adverseEvents[deviceId][aeIdx].patientAge);
        FHE.allowThis(adverseEvents[deviceId][aeIdx].implantDurationMonths);
        FHE.allowThis(d.adverseEventCount); FHE.allowThis(d.seriousInjuryCount);
        FHE.allowThis(d.deathCount); FHE.allowThis(d.malfunctionCount);
        FHE.allowThis(d.estimatedPatientRisk); FHE.allowThis(_totalAEsReported);

        // Auto-alert if risk score > 1000
        ebool highRisk = FHE.gt(d.estimatedPatientRisk, FHE.asEuint64(1000));
        if (FHE.isInitialized(highRisk)) emit RiskAlertIssued(deviceId);

        emit AdverseEventReported(deviceId, severity);
    }

    function initiateRecall(
        uint256 deviceId,
        RecallStatus recallType,
        externalEuint32 encAffectedUnits, bytes calldata unitsProof,
        externalEuint64 encCostUSD, bytes calldata costProof,
        string calldata reasonCode
    ) external onlyRegulator {
        MedicalDevice storage d = devices[deviceId];
        euint32 affectedUnits = FHE.fromExternal(encAffectedUnits, unitsProof);
        euint64 costUSD = FHE.fromExternal(encCostUSD, costProof);
        euint64 costUSDWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 costUSDExposure = FHE.sub(costUSDWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]

        d.recallStatus = recallType;
        uint256 recallIdx = recalls[deviceId].length;
        recalls[deviceId].push(RecallRecord({
            deviceId: deviceId,
            recallType: recallType,
            affectedUnits: affectedUnits,
            estimatedCostUSD: costUSD,
            reasonCode: reasonCode,
            initiatedAt: block.timestamp,
            completed: false
        }));

        _totalUnitsRecalled = FHE.add(_totalUnitsRecalled, FHE.asEuint64(affectedUnits));
        _totalRecallCostUSD = FHE.add(_totalRecallCostUSD, costUSD);

        FHE.allowThis(recalls[deviceId][recallIdx].affectedUnits);
        FHE.allowThis(recalls[deviceId][recallIdx].estimatedCostUSD);
        FHE.allowThis(_totalUnitsRecalled); FHE.allowThis(_totalRecallCostUSD);

        emit RecallInitiated(deviceId, recallType);
    }

    function completeRecall(uint256 deviceId, uint256 recallIdx) external onlyRegulator {
        recalls[deviceId][recallIdx].completed = true;
        emit RecallCompleted(deviceId);
    }

    function allowDeviceView(uint256 deviceId, address viewer) external onlyRegulator {
        FHE.allow(devices[deviceId].adverseEventCount, viewer); // [acl_misconfig]
        FHE.allow(_totalAEsReported, msg.sender); // [acl_misconfig]
        FHE.allow(_totalUnitsRecalled, msg.sender); // [acl_misconfig]
        FHE.allow(devices[deviceId].deathCount, viewer);
        FHE.allow(devices[deviceId].seriousInjuryCount, viewer);
        FHE.allow(devices[deviceId].estimatedPatientRisk, viewer);
    }

    function allowSurveillanceStats(address viewer) external onlyOwner {
        FHE.allow(_totalAEsReported, viewer);
        FHE.allow(_totalUnitsRecalled, viewer);
        FHE.allow(_totalRecallCostUSD, viewer);
    }
}
