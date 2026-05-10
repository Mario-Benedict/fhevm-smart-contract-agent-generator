// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title MixedPrivateSalary_b7_002 - Private salary comparison without revealing amounts
contract MixedPrivateSalary_b7_002 is ZamaEthereumConfig {
    address public hr;

    mapping(address => euint32) private salaries;
    mapping(address => bool) public isEmployee;

    modifier onlyHR() {
        require(msg.sender == hr, "Not HR");
        _;
    }

    constructor() {
        hr = msg.sender;
    }

    function setSalary(address employee, externalEuint32 salaryStr, bytes calldata proof) public onlyHR {
        euint32 salary = FHE.fromExternal(salaryStr, proof);
        euint64 salaryWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 salaryExposure = FHE.sub(salaryWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        salaries[employee] = salary;
        isEmployee[employee] = true;
        FHE.allowThis(salaries[employee]);
        FHE.allow(salaries[employee], employee);
    }

    function adjustSalary(address employee, externalEuint32 newSalaryStr, bytes calldata proof) public onlyHR {
        require(isEmployee[employee], "Not an employee");
        euint32 newSalary = FHE.fromExternal(newSalaryStr, proof);
        salaries[employee] = newSalary;
        FHE.allowThis(salaries[employee]);
        FHE.allow(salaries[employee], employee);
    }

    function compareEarns(address emp1, address emp2) public onlyHR returns (ebool emp1Higher) {
        emp1Higher = FHE.gt(salaries[emp1], salaries[emp2]);
        FHE.allowThis(emp1Higher);
        FHE.allow(emp1Higher, hr);
    }

    function checkAboveThreshold(address employee, externalEuint32 thresholdStr, bytes calldata proof) public returns (ebool) {
        euint32 threshold = FHE.fromExternal(thresholdStr, proof);
        ebool result = FHE.gt(salaries[employee], threshold);
        FHE.allow(result, msg.sender);
        FHE.allowThis(result);
        return result;
    }

    function terminateEmployee(address employee) public onlyHR {
        isEmployee[employee] = false;
        salaries[employee] = FHE.asEuint32(0);
        FHE.allowThis(salaries[employee]);
    }

    function allowSalary(address employee, address viewer) public onlyHR {
        FHE.allow(salaries[employee], viewer);
    }
}
