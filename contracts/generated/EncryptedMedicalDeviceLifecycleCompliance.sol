// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedMedicalDeviceLifecycleCompliance
/// @notice Medical device lifecycle tracking with encrypted adverse event rates,
///         calibration compliance, maintenance costs, and post-market surveillance data.
contract EncryptedMedicalDeviceLifecycleCompliance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DeviceClass { CLASS_I, CLASS_II, CLASS_III, IN_VITRO_DIAGNOSTIC }
    enum DeviceStatus { ACTIVE, MAINTENANCE, RETIRED, RECALLED, INVESTIGATION }

    struct MedicalDevice {
        string serialNumber;
        string udCode;                // Unique Device Identifier
        string deviceType;
        DeviceClass deviceClass;
        address manufacturer;
        address currentFacility;
        euint64 acquisitionCostUSD;   // encrypted purchase price
        euint64 currentValueUSD;      // encrypted book value
        euint64 maintenanceCostYTD;   // encrypted maintenance spend
        euint64 revenueGeneratedUSD;  // encrypted patient revenue
        euint8  safetyScore;          // encrypted FDA safety rating 0-100
        euint8  calibrationScore;     // encrypted calibration compliance 0-100
        euint32 patientsServed;       // encrypted utilization count
        euint32 adverseEventCount;    // encrypted reported adverse events
        uint256 manufactureDate;
        uint256 lastCalibrationDate;
        uint256 nextCalibrationDue;
        DeviceStatus status;
    }

    struct PostMarketSurveillance {
        uint256 deviceId;
        euint8  monthlyFailureRate;   // encrypted failure/100k hours
        euint32 complaintsReceived;   // encrypted complaint count
        euint64 recallCostUSD;        // encrypted recall expense if any
        euint8  regulatoryRiskScore;  // encrypted 0-100 risk
        uint256 reportDate;
        bool escalated;
    }

    mapping(uint256 => MedicalDevice) private devices;
    mapping(uint256 => PostMarketSurveillance) private surveillanceReports;
    mapping(address => bool) public isRegulator;
    mapping(address => bool) public isBiomedEngineer;
    uint256 public deviceCount;
    uint256 public surveillanceCount;
    euint64 private _totalFleetValue;
    euint64 private _totalMaintenanceCosts;
    euint64 private _totalAdverseEvents;

    event DeviceRegistered(uint256 indexed deviceId, DeviceClass dClass, string udCode);
    event CalibrationUpdated(uint256 indexed deviceId);
    event SurveillanceReported(uint256 indexed reportId, uint256 deviceId);
    event DeviceRecalled(uint256 indexed deviceId);
    event AdverseEventReported(uint256 indexed deviceId);

    constructor() Ownable(msg.sender) {
        _totalFleetValue = FHE.asEuint64(0);
        _totalMaintenanceCosts = FHE.asEuint64(0);
        _totalAdverseEvents = FHE.asEuint64(0);
        FHE.allowThis(_totalFleetValue);
        FHE.allowThis(_totalMaintenanceCosts);
        FHE.allowThis(_totalAdverseEvents);
        isRegulator[msg.sender] = true;
        isBiomedEngineer[msg.sender] = true;
    }

    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }
    function addEngineer(address e) external onlyOwner { isBiomedEngineer[e] = true; }

    function registerDevice(
        string calldata serial, string calldata udc, string calldata devType,
        DeviceClass dClass, address facility,
        externalEuint64 encCost,     bytes calldata costProof,
        externalEuint8  encSafety,   bytes calldata safetyProof,
        externalEuint8  encCalib,    bytes calldata calibProof,
        uint256 nextCalibDue
    ) external returns (uint256 deviceId) {
        euint64 cost   = FHE.fromExternal(encCost, costProof);
        euint8  safety = FHE.fromExternal(encSafety, safetyProof);
        euint8  calib  = FHE.fromExternal(encCalib, calibProof);
        deviceId = deviceCount++;
        devices[deviceId] = MedicalDevice({
            serialNumber: serial, udCode: udc, deviceType: devType,
            deviceClass: dClass, manufacturer: msg.sender, currentFacility: facility,
            acquisitionCostUSD: cost, currentValueUSD: cost,
            maintenanceCostYTD: FHE.asEuint64(0), revenueGeneratedUSD: FHE.asEuint64(0),
            safetyScore: safety, calibrationScore: calib,
            patientsServed: FHE.asEuint32(0), adverseEventCount: FHE.asEuint32(0),
            manufactureDate: block.timestamp,
            lastCalibrationDate: block.timestamp, nextCalibrationDue: nextCalibDue,
            status: DeviceStatus.ACTIVE
        });
        _totalFleetValue = FHE.add(_totalFleetValue, cost);
        FHE.allowThis(devices[deviceId].acquisitionCostUSD);
        FHE.allow(devices[deviceId].acquisitionCostUSD, facility);
        FHE.allowThis(devices[deviceId].currentValueUSD);
        FHE.allowThis(devices[deviceId].maintenanceCostYTD);
        FHE.allow(devices[deviceId].maintenanceCostYTD, facility);
        FHE.allowThis(devices[deviceId].revenueGeneratedUSD);
        FHE.allowThis(devices[deviceId].safetyScore);
        FHE.allow(devices[deviceId].safetyScore, facility);
        FHE.allowThis(devices[deviceId].calibrationScore);
        FHE.allow(devices[deviceId].calibrationScore, facility);
        FHE.allowThis(devices[deviceId].patientsServed);
        FHE.allowThis(devices[deviceId].adverseEventCount);
        FHE.allowThis(_totalFleetValue);
        emit DeviceRegistered(deviceId, dClass, udc);
    }

    function updateCalibration(
        uint256 deviceId,
        externalEuint8 encCalibScore, bytes calldata proof,
        uint256 nextDue
    ) external {
        require(isBiomedEngineer[msg.sender], "Not engineer");
        devices[deviceId].calibrationScore = FHE.fromExternal(encCalibScore, proof);
        devices[deviceId].lastCalibrationDate = block.timestamp;
        devices[deviceId].nextCalibrationDue = nextDue;
        FHE.allowThis(devices[deviceId].calibrationScore);
        FHE.allow(devices[deviceId].calibrationScore, devices[deviceId].currentFacility);
        emit CalibrationUpdated(deviceId);
    }

    function reportAdverseEvent(uint256 deviceId) external {
        require(isRegulator[msg.sender] || isBiomedEngineer[msg.sender], "Unauthorized");
        devices[deviceId].adverseEventCount = FHE.add(devices[deviceId].adverseEventCount, FHE.asEuint32(1));
        _totalAdverseEvents = FHE.add(_totalAdverseEvents, FHE.asEuint64(1));
        FHE.allowThis(devices[deviceId].adverseEventCount);
        FHE.allowThis(_totalAdverseEvents);
        emit AdverseEventReported(deviceId);
    }

    function recordMaintenanceCost(
        uint256 deviceId,
        externalEuint64 encCost, bytes calldata proof
    ) external {
        require(isBiomedEngineer[msg.sender], "Not engineer");
        euint64 cost = FHE.fromExternal(encCost, proof);
        devices[deviceId].maintenanceCostYTD = FHE.add(devices[deviceId].maintenanceCostYTD, cost);
        _totalMaintenanceCosts = FHE.add(_totalMaintenanceCosts, cost);
        FHE.allowThis(devices[deviceId].maintenanceCostYTD);
        FHE.allowThis(_totalMaintenanceCosts);
    }

    function submitSurveillanceReport(
        uint256 deviceId,
        externalEuint8  encFailureRate, bytes calldata frProof,
        externalEuint32 encComplaints,  bytes calldata cProof,
        externalEuint8  encRegRisk,     bytes calldata rrProof
    ) external returns (uint256 reportId) {
        require(isRegulator[msg.sender], "Not regulator");
        euint8  failRate   = FHE.fromExternal(encFailureRate, frProof);
        euint32 complaints = FHE.fromExternal(encComplaints, cProof);
        euint8  regRisk    = FHE.fromExternal(encRegRisk, rrProof);
        reportId = surveillanceCount++;
        surveillanceReports[reportId] = PostMarketSurveillance({
            deviceId: deviceId, monthlyFailureRate: failRate,
            complaintsReceived: complaints, recallCostUSD: FHE.asEuint64(0),
            regulatoryRiskScore: regRisk, reportDate: block.timestamp, escalated: false
        });
        FHE.allowThis(surveillanceReports[reportId].monthlyFailureRate);
        FHE.allowThis(surveillanceReports[reportId].complaintsReceived);
        FHE.allowThis(surveillanceReports[reportId].regulatoryRiskScore);
        FHE.allowThis(surveillanceReports[reportId].recallCostUSD);
        emit SurveillanceReported(reportId, deviceId);
    }

    function recallDevice(uint256 deviceId) external {
        require(isRegulator[msg.sender], "Not regulator");
        devices[deviceId].status = DeviceStatus.RECALLED;
        emit DeviceRecalled(deviceId);
    }

    function allowComplianceView(address viewer) external onlyOwner {
        FHE.allow(_totalFleetValue, viewer);
        FHE.allow(_totalMaintenanceCosts, viewer);
        FHE.allow(_totalAdverseEvents, viewer);
    }
}
