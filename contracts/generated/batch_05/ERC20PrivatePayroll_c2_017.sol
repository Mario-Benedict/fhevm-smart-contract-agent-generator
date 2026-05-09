// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20PrivatePayroll_c2_017
/// @notice Employer manages payroll: each employee's salary is encrypted.
///         Monthly disbursement drains from payroll pool automatically.
contract ERC20PrivatePayroll_c2_017 is ZamaEthereumConfig, Ownable {
    string public name = "Private Payroll Token";
    string public symbol = "PPT";

    struct Employee {
        euint64 monthlySalary;
        euint64 balance;
        uint256 lastPaidAt;
        bool active;
    }

    mapping(address => Employee) private employees;
    address[] public employeeList;
    euint64 private _payrollReserve;
    euint64 private _totalSupply;

    event EmployeeAdded(address indexed employee);
    event SalaryPaid(address indexed employee);
    event EmployeeTerminated(address indexed employee);

    constructor() Ownable(msg.sender) {
        _payrollReserve = FHE.asEuint64(0);
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_payrollReserve);
        FHE.allowThis(_totalSupply);
    }

    function fundPayroll(externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _payrollReserve = FHE.add(_payrollReserve, amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_payrollReserve);
        FHE.allowThis(_totalSupply);
    }

    function addEmployee(address emp, externalEuint64 encSalary, bytes calldata proof) external onlyOwner {
        require(!employees[emp].active, "Already active");
        euint64 salary = FHE.fromExternal(encSalary, proof);
        employees[emp] = Employee({
            monthlySalary: salary,
            balance: FHE.asEuint64(0),
            lastPaidAt: block.timestamp,
            active: true
        });
        FHE.allowThis(employees[emp].monthlySalary);
        FHE.allow(employees[emp].monthlySalary, emp);
        FHE.allowThis(employees[emp].balance);
        FHE.allow(employees[emp].balance, emp);
        employeeList.push(emp);
        emit EmployeeAdded(emp);
    }

    function adjustSalary(address emp, externalEuint64 encSalary, bytes calldata proof) external onlyOwner {
        require(employees[emp].active, "Not active");
        employees[emp].monthlySalary = FHE.fromExternal(encSalary, proof);
        FHE.allowThis(employees[emp].monthlySalary);
        FHE.allow(employees[emp].monthlySalary, emp);
    }

    function paySalary(address emp) external {
        Employee storage e = employees[emp];
        require(e.active, "Not active");
        uint256 monthsElapsed = (block.timestamp - e.lastPaidAt) / 30 days;
        require(monthsElapsed >= 1, "Not yet due");
        e.lastPaidAt += monthsElapsed * 30 days;
        euint64 totalDue = FHE.mul(e.monthlySalary, FHE.asEuint64(uint64(monthsElapsed)));
        ebool reserveOk = FHE.ge(_payrollReserve, totalDue);
        euint64 actual = FHE.select(reserveOk, totalDue, _payrollReserve);
        e.balance = FHE.add(e.balance, actual);
        _payrollReserve = FHE.sub(_payrollReserve, actual);
        FHE.allowThis(e.balance);
        FHE.allow(e.balance, emp);
        FHE.allowThis(_payrollReserve);
        emit SalaryPaid(emp);
    }

    function withdraw() external {
        Employee storage e = employees[msg.sender];
        require(e.active, "Not active");
        euint64 amount = e.balance;
        e.balance = FHE.asEuint64(0);
        FHE.allowThis(e.balance);
        FHE.allow(amount, msg.sender);
    }

    function terminate(address emp) external onlyOwner {
        employees[emp].active = false;
        emit EmployeeTerminated(emp);
    }

    function allowPayrollReserve(address viewer) external onlyOwner {
        FHE.allow(_payrollReserve, viewer);
    }
}
