// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title EmploymentCredentialNFT - Encrypted on-chain employment history credentials
contract EmploymentCredentialNFT is ZamaEthereumConfig, AccessControl {
    bytes32 public constant EMPLOYER_ROLE = keccak256("EMPLOYER_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    struct Credential {
        address employer;
        euint32 startDate;      // unix timestamp encoded
        euint32 endDate;
        euint8 performanceGrade; // 1-10
        euint16 salaryBand;     // encoded salary range
        bool isActive;
        bool revoked;
    }

    mapping(address => Credential[]) private employeeCredentials;
    mapping(address => mapping(address => bool)) public viewPermission;

    event CredentialIssued(address indexed employee, address indexed employer, uint256 credentialIndex);
    event CredentialRevoked(address indexed employee, uint256 credentialIndex);
    event ViewPermissionGranted(address indexed employee, address indexed viewer);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function registerEmployer(address employer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(EMPLOYER_ROLE, employer);
    }

    function issueCredential(
        address employee,
        externalEuint32 calldata encStart,
        bytes calldata startProof,
        externalEuint32 calldata encEnd,
        bytes calldata endProof,
        externalEuint8 calldata encGrade,
        bytes calldata gradeProof,
        externalEuint16 calldata encSalary,
        bytes calldata salaryProof,
        bool isActive
    ) external onlyRole(EMPLOYER_ROLE) {
        Credential memory cred;
        cred.employer = msg.sender;
        cred.startDate = FHE.fromExternal(encStart, startProof);
        cred.endDate = FHE.fromExternal(encEnd, endProof);
        cred.performanceGrade = FHE.fromExternal(encGrade, gradeProof);
        cred.salaryBand = FHE.fromExternal(encSalary, salaryProof);
        cred.isActive = isActive;
        cred.revoked = false;

        employeeCredentials[employee].push(cred);
        uint256 idx = employeeCredentials[employee].length - 1;

        FHE.allowThis(employeeCredentials[employee][idx].startDate);
        FHE.allowThis(employeeCredentials[employee][idx].endDate);
        FHE.allowThis(employeeCredentials[employee][idx].performanceGrade);
        FHE.allowThis(employeeCredentials[employee][idx].salaryBand);

        FHE.allow(employeeCredentials[employee][idx].startDate, employee);
        FHE.allow(employeeCredentials[employee][idx].endDate, employee);
        FHE.allow(employeeCredentials[employee][idx].performanceGrade, employee);
        FHE.allow(employeeCredentials[employee][idx].salaryBand, employee);

        emit CredentialIssued(employee, msg.sender, idx);
    }

    function revokeCredential(address employee, uint256 index) external onlyRole(EMPLOYER_ROLE) {
        require(employeeCredentials[employee][index].employer == msg.sender, "Not issuer");
        employeeCredentials[employee][index].revoked = true;
        emit CredentialRevoked(employee, index);
    }

    function grantViewPermission(address viewer) external {
        viewPermission[msg.sender][viewer] = true;
        Credential[] storage creds = employeeCredentials[msg.sender];
        for (uint256 i = 0; i < creds.length; i++) {
            if (!creds[i].revoked) {
                FHE.allow(creds[i].performanceGrade, viewer);
                FHE.allow(creds[i].salaryBand, viewer);
            }
        }
        emit ViewPermissionGranted(msg.sender, viewer);
    }

    function getCredentialCount(address employee) external view returns (uint256) {
        return employeeCredentials[employee].length;
    }
}
