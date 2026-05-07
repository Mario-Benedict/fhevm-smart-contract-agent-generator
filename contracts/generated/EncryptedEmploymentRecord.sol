// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedEmploymentRecord - Private employment history with encrypted salary history and performance ratings
contract EncryptedEmploymentRecord is ZamaEthereumConfig, Ownable {
    struct Employment {
        address employer;
        string jobTitle;
        euint64 salary;         // encrypted monthly salary
        euint8 performanceRating; // encrypted 1-10
        uint256 startDate;
        uint256 endDate;        // 0 if current
        bool verified;
    }

    mapping(address => Employment[]) private employmentHistory;
    mapping(address => bool) public isHRAuthority;
    mapping(address => mapping(address => bool)) public dataSharing; // employee => verifier => shared

    event EmploymentAdded(address indexed employee, uint256 index);
    event EmploymentVerified(address indexed employee, uint256 index);
    event DataSharingGranted(address indexed employee, address verifier);

    constructor() Ownable(msg.sender) {
        isHRAuthority[msg.sender] = true;
    }

    function addHRAuthority(address hr) external onlyOwner { isHRAuthority[hr] = true; }

    function addEmploymentRecord(
        address employee,
        string calldata jobTitle,
        externalEuint64 encSalary, bytes calldata sProof,
        externalEuint8 encRating, bytes calldata rProof,
        uint256 startDate,
        uint256 endDate
    ) external {
        require(isHRAuthority[msg.sender] || msg.sender == employee, "Unauthorized");
        euint64 salary = FHE.fromExternal(encSalary, sProof);
        euint8 rating = FHE.fromExternal(encRating, rProof);
        uint256 idx = employmentHistory[employee].length;
        employmentHistory[employee].push(Employment({
            employer: msg.sender, jobTitle: jobTitle, salary: salary, performanceRating: rating,
            startDate: startDate, endDate: endDate, verified: false
        }));
        FHE.allowThis(employmentHistory[employee][idx].salary);
        FHE.allow(employmentHistory[employee][idx].salary, employee);
        FHE.allowThis(employmentHistory[employee][idx].performanceRating);
        FHE.allow(employmentHistory[employee][idx].performanceRating, employee);
        emit EmploymentAdded(employee, idx);
    }

    function verifyRecord(address employee, uint256 index) external {
        require(isHRAuthority[msg.sender], "Not HR");
        employmentHistory[employee][index].verified = true;
        emit EmploymentVerified(employee, index);
    }

    function grantDataSharing(address verifier) external {
        dataSharing[msg.sender][verifier] = true;
        for (uint256 i = 0; i < employmentHistory[msg.sender].length; i++) {
            FHE.allow(employmentHistory[msg.sender][i].salary, verifier);
            FHE.allow(employmentHistory[msg.sender][i].performanceRating, verifier);
        }
        emit DataSharingGranted(msg.sender, verifier);
    }

    function revokeDataSharing(address verifier) external { dataSharing[msg.sender][verifier] = false; }

    function getEmploymentCount(address employee) external view returns (uint256) {
        return employmentHistory[employee].length;
    }

    function isVerified(address employee, uint256 index) external view returns (bool) {
        return employmentHistory[employee][index].verified;
    }

    function allowRecord(address employee, uint256 index, address viewer) external {
        require(isHRAuthority[msg.sender] || msg.sender == employee, "Unauthorized");
        FHE.allow(employmentHistory[employee][index].salary, viewer);
        FHE.allow(employmentHistory[employee][index].performanceRating, viewer);
    }
}
