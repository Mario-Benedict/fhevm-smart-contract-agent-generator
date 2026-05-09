// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedBuildingAccessControl - Physical building access management with encrypted clearance levels
contract EncryptedBuildingAccessControl is ZamaEthereumConfig, Ownable {
    struct Employee {
        euint8 clearanceLevel;  // encrypted 1-5 security clearance
        euint32 employeeId;     // encrypted employee ID
        mapping(uint256 => bool) zoneAccess; // zone => has physical access card
        uint256 hireDate;
        bool active;
    }

    struct Zone {
        string name;
        euint8 requiredClearance; // encrypted minimum clearance
        bool exists;
    }

    mapping(address => Employee) private employees;
    mapping(uint256 => Zone) private zones;
    uint256 public zoneCount;
    mapping(address => bool) public isSecurityManager;
    mapping(uint256 => uint256) public accessLog; // zone => count of accesses (plaintext)

    event EmployeeEnrolled(address indexed emp);
    event ZoneCreated(uint256 indexed zoneId, string name);
    event AccessGranted(address indexed emp, uint256 zoneId);
    event AccessDenied(address indexed emp, uint256 zoneId);

    constructor() Ownable(msg.sender) {
        isSecurityManager[msg.sender] = true;
    }

    function addSecurityManager(address sm) external onlyOwner { isSecurityManager[sm] = true; }

    function enrollEmployee(address emp, externalEuint8 encClearance, bytes calldata cProof,
                           externalEuint32 encEmpId, bytes calldata idProof) external {
        require(isSecurityManager[msg.sender], "Not security manager");
        euint8 clearance = FHE.fromExternal(encClearance, cProof);
        euint32 empId = FHE.fromExternal(encEmpId, idProof);
        employees[emp].clearanceLevel = clearance;
        employees[emp].employeeId = empId;
        employees[emp].hireDate = block.timestamp;
        employees[emp].active = true;
        FHE.allowThis(employees[emp].clearanceLevel);
        FHE.allow(employees[emp].clearanceLevel, emp);
        FHE.allowThis(employees[emp].employeeId);
        FHE.allow(employees[emp].employeeId, emp);
        emit EmployeeEnrolled(emp);
    }

    function createZone(string calldata name, externalEuint8 encReqClearance, bytes calldata proof) external returns (uint256 zoneId) {
        require(isSecurityManager[msg.sender], "Not security manager");
        euint8 req = FHE.fromExternal(encReqClearance, proof);
        zoneId = zoneCount++;
        zones[zoneId] = Zone({ name: name, requiredClearance: req, exists: true });
        FHE.allowThis(zones[zoneId].requiredClearance);
        emit ZoneCreated(zoneId, name);
    }

    function requestAccess(uint256 zoneId) external returns (ebool granted) {
        require(employees[msg.sender].active, "Not active");
        require(zones[zoneId].exists, "Zone not found");
        granted = FHE.ge(employees[msg.sender].clearanceLevel, zones[zoneId].requiredClearance);
        FHE.allow(granted, msg.sender);
        FHE.allowThis(granted);
        if (FHE.isInitialized(granted)) {
            employees[msg.sender].zoneAccess[zoneId] = true;
            accessLog[zoneId]++;
            emit AccessGranted(msg.sender, zoneId);
        } else {
            emit AccessDenied(msg.sender, zoneId);
        }
    }

    function updateClearance(address emp, externalEuint8 encClearance, bytes calldata proof) external {
        require(isSecurityManager[msg.sender], "Not security manager");
        euint8 clearance = FHE.fromExternal(encClearance, proof);
        employees[emp].clearanceLevel = clearance;
        FHE.allowThis(employees[emp].clearanceLevel);
        FHE.allow(employees[emp].clearanceLevel, emp);
    }

    function deactivate(address emp) external {
        require(isSecurityManager[msg.sender], "Not security manager");
        employees[emp].active = false;
    }

    function allowEmployeeData(address emp, address viewer) external {
        require(isSecurityManager[msg.sender] || msg.sender == emp, "Unauthorized");
        FHE.allow(employees[emp].clearanceLevel, viewer);
        FHE.allow(employees[emp].employeeId, viewer);
    }
}
