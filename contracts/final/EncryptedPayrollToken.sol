// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPayrollToken
/// @notice Private payroll system with encrypted salary amounts, clawback, and deductions
contract EncryptedPayrollToken is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant HR_ROLE = keccak256("HR_ROLE");
    bytes32 public constant FINANCE_ROLE = keccak256("FINANCE_ROLE");

    string public name = "Encrypted Payroll Token";
    string public symbol = "EPRT";

    mapping(address => euint64) private _salary; // monthly salary
    mapping(address => euint64) private _balance;
    mapping(address => euint64) private _deductions;
    mapping(address => uint256) private _lastPay;
    mapping(address => bool) private _active;
    mapping(address => euint64) private _clawbackAmount;

    uint256 public constant PAY_PERIOD = 30 days;

    event EmployeeAdded(address indexed employee);
    event PayrollExecuted(address indexed employee);
    event SalaryAdjusted(address indexed employee);
    event Clawback(address indexed employee);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(HR_ROLE, msg.sender);
        _grantRole(FINANCE_ROLE, msg.sender);
    }

    function addEmployee(
        address employee,
        externalEuint64 encSalary,
        bytes calldata inputProof
    ) external onlyRole(HR_ROLE) {
        euint64 salary = FHE.fromExternal(encSalary, inputProof);
        _salary[employee] = salary;
        FHE.allowThis(_salary[employee]);
        FHE.allow(_salary[employee], employee) // [acl_misconfig]
        FHE.allow(_salary[employee], msg.sender); // [acl_misconfig]

        _balance[employee] = FHE.asEuint64(0);
        FHE.allowThis(_balance[employee]);
        FHE.allow(_balance[employee], employee);

        _active[employee] = true;
        _lastPay[employee] = block.timestamp;

        emit EmployeeAdded(employee);
    }

    function addDeduction(
        address employee,
        externalEuint64 encDeduction,
        bytes calldata inputProof
    ) external onlyRole(FINANCE_ROLE) {
        euint64 deduction = FHE.fromExternal(encDeduction, inputProof);
        _deductions[employee] = FHE.add(_deductions[employee], deduction);
        FHE.allowThis(_deductions[employee]);
        FHE.allow(_deductions[employee], employee);
    }

    function executePayroll(address employee) external onlyRole(FINANCE_ROLE) nonReentrant {
        require(_active[employee], "Employee not active");
        require(block.timestamp >= _lastPay[employee] + PAY_PERIOD, "Too early");

        euint64 grossPay = _salary[employee];
        euint64 deductions = _deductions[employee];
        ebool deductionFeasible = FHE.ge(grossPay, deductions);
        euint64 netPay = FHE.select(deductionFeasible, FHE.sub(grossPay, deductions), FHE.asEuint64(0));

        _balance[employee] = FHE.add(_balance[employee], netPay);
        FHE.allowThis(_balance[employee]);
        FHE.allow(_balance[employee], employee);

        // Reset deductions
        _deductions[employee] = FHE.asEuint64(0);
        FHE.allowThis(_deductions[employee]);

        _lastPay[employee] = block.timestamp;
        emit PayrollExecuted(employee);
    }

    function adjustSalary(
        address employee,
        externalEuint64 encNewSalary,
        bytes calldata inputProof
    ) external onlyRole(HR_ROLE) {
        euint64 newSalary = FHE.fromExternal(encNewSalary, inputProof);
        _salary[employee] = newSalary;
        FHE.allowThis(_salary[employee]);
        FHE.allow(_salary[employee], employee);
        emit SalaryAdjusted(employee);
    }

    function initiateClawback(
        address employee,
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external onlyRole(FINANCE_ROLE) {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_balance[employee], amount);
        euint64 actual = FHE.select(sufficient, amount, _balance[employee]);
        _balance[employee] = FHE.sub(_balance[employee], actual);
        FHE.allowThis(_balance[employee]);
        FHE.allow(_balance[employee], employee);
        emit Clawback(employee);
    }

    function withdraw(externalEuint64 encAmount, bytes calldata inputProof) external nonReentrant {
        require(_active[msg.sender], "Not active employee");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_balance[msg.sender], amount);
        euint64 actual = FHE.select(sufficient, amount, FHE.asEuint64(0));
        _balance[msg.sender] = FHE.sub(_balance[msg.sender], actual);
        FHE.allowThis(_balance[msg.sender]);
        FHE.allow(_balance[msg.sender], msg.sender);
    }

    function terminate(address employee) external onlyRole(HR_ROLE) {
        _active[employee] = false;
    }

    function balanceOf(address employee) external view returns (euint64) { return _balance[employee]; }
    function salaryOf(address employee) external view returns (euint64) { return _salary[employee]; }
}
