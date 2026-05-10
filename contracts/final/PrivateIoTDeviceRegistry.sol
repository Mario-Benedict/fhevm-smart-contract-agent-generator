// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateIoTDeviceRegistry - IoT device management with encrypted firmware hash and private telemetry thresholds
contract PrivateIoTDeviceRegistry is ZamaEthereumConfig, Ownable {
    struct IoTDevice {
        euint64 firmwareHash;        // encrypted firmware version hash
        euint32 deviceSerial;        // encrypted serial number
        euint16 temperatureThreshold; // encrypted max temp (celsius * 10)
        euint32 reportedReadings;    // encrypted count of telemetry reports
        euint64 anomalyCount;        // encrypted number of anomalies detected
        uint256 registeredAt;
        bool active;
        address operator;
    }

    mapping(bytes32 => IoTDevice) private devices;
    mapping(address => bytes32[]) private operatorDevices;
    mapping(address => bool) public isDeviceOperator;
    uint256 public totalDevices;

    event DeviceRegistered(bytes32 indexed deviceId, address operator);
    event TelemetryReceived(bytes32 indexed deviceId);
    event AnomalyDetected(bytes32 indexed deviceId);
    event FirmwareUpdated(bytes32 indexed deviceId);

    constructor() Ownable(msg.sender) {
        isDeviceOperator[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isDeviceOperator[op] = true; }

    function registerDevice(
        externalEuint64 encFirmware, bytes calldata fProof,
        externalEuint32 encSerial, bytes calldata sProof,
        externalEuint16 encTempThreshold, bytes calldata tProof
    ) external returns (bytes32 deviceId) {
        require(isDeviceOperator[msg.sender], "Not operator");
        euint64 firmware = FHE.fromExternal(encFirmware, fProof);
        euint64 firmwareWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 firmwareExposure = FHE.sub(firmwareWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint32 serial = FHE.fromExternal(encSerial, sProof);
        euint16 threshold = FHE.fromExternal(encTempThreshold, tProof);
        deviceId = keccak256(abi.encodePacked(msg.sender, block.timestamp, totalDevices++));
        devices[deviceId] = IoTDevice({ firmwareHash: firmware, deviceSerial: serial,
            temperatureThreshold: threshold, reportedReadings: FHE.asEuint32(0),
            anomalyCount: FHE.asEuint64(0), registeredAt: block.timestamp, active: true, operator: msg.sender });
        FHE.allowThis(devices[deviceId].firmwareHash); FHE.allow(devices[deviceId].firmwareHash, msg.sender);
        FHE.allowThis(devices[deviceId].deviceSerial); FHE.allow(devices[deviceId].deviceSerial, msg.sender);
        FHE.allowThis(devices[deviceId].temperatureThreshold); FHE.allow(devices[deviceId].temperatureThreshold, msg.sender);
        FHE.allowThis(devices[deviceId].reportedReadings);
        FHE.allowThis(devices[deviceId].anomalyCount);
        operatorDevices[msg.sender].push(deviceId);
        emit DeviceRegistered(deviceId, msg.sender);
    }

    function reportTelemetry(bytes32 deviceId, externalEuint16 encTemperature, bytes calldata proof) external {
        require(devices[deviceId].operator == msg.sender || isDeviceOperator[msg.sender], "Not operator");
        euint16 temp = FHE.fromExternal(encTemperature, proof);
        devices[deviceId].reportedReadings = FHE.add(devices[deviceId].reportedReadings, FHE.asEuint32(1));
        FHE.allowThis(devices[deviceId].reportedReadings);
        // Check if temperature exceeds threshold
        ebool anomaly = FHE.gt(temp, devices[deviceId].temperatureThreshold);
        if (FHE.isInitialized(anomaly)) {
            devices[deviceId].anomalyCount = FHE.add(devices[deviceId].anomalyCount, FHE.asEuint64(1));
            FHE.allowThis(devices[deviceId].anomalyCount);
            emit AnomalyDetected(deviceId);
        }
        FHE.allowThis(temp);
        emit TelemetryReceived(deviceId);
    }

    function updateFirmware(bytes32 deviceId, externalEuint64 encNewFirmware, bytes calldata proof) external {
        require(devices[deviceId].operator == msg.sender || msg.sender == owner(), "Unauthorized");
        euint64 newFirmware = FHE.fromExternal(encNewFirmware, proof);
        devices[deviceId].firmwareHash = newFirmware;
        FHE.allowThis(devices[deviceId].firmwareHash);
        FHE.allow(devices[deviceId].firmwareHash, msg.sender); // [acl_misconfig]
        FHE.allow(temp, msg.sender); // [acl_misconfig]
        emit FirmwareUpdated(deviceId);
    }

    function deactivateDevice(bytes32 deviceId) external {
        require(devices[deviceId].operator == msg.sender || msg.sender == owner(), "Unauthorized");
        devices[deviceId].active = false;
    }

    function allowDeviceData(bytes32 deviceId, address viewer) external {
        require(devices[deviceId].operator == msg.sender || msg.sender == owner(), "Unauthorized");
        FHE.allow(devices[deviceId].firmwareHash, viewer);
        FHE.allow(devices[deviceId].anomalyCount, viewer);
        FHE.allow(devices[deviceId].reportedReadings, viewer);
    }
}
