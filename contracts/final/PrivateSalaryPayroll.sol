// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateSalaryPayroll - Encrypted employee payroll system with confidential salary data
contract PrivateSalaryPayroll is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant HR_ROLE = keccak256("HR_ROLE");
    bytes32 public constant PAYROLL_ROLE = keccak256("PAYROLL_ROLE");
    bytes32 public constant EMPLOYEE_ROLE = keccak256("EMPLOYEE_ROLE");

    struct Employee {
        euint64 baseSalary;
        euint64 bonus;
        euint32 taxCode;
        euint8 payGrade;
        euint64 totalPaid;
        bool active;
        uint256 lastPayDate;
    }

    struct PayRunRecord {
        uint256 payDate;
        euint64 grossAmount;
        euint64 taxDeducted;
        euint64 netAmount;
    }

    mapping(address => Employee) public employees;
    mapping(address => PayRunRecord[]) private payHistory;
    euint64 private totalPayrollExpense;
    uint256 public employeeCount;

    event EmployeeOnboarded(address indexed employee);
    event SalaryUpdated(address indexed employee);
    event PaymentProcessed(address indexed employee, uint256 payDate);
    event BonusGranted(address indexed employee);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(HR_ROLE, msg.sender);
        _grantRole(PAYROLL_ROLE, msg.sender);
        totalPayrollExpense = FHE.asEuint64(0);
        FHE.allowThis(totalPayrollExpense);
    }

    function onboardEmployee(
        address employee,
        externalEuint64 encSalary,
        bytes calldata salaryProof,
        externalEuint32 encTax,
        bytes calldata taxProof,
        externalEuint8 encGrade,
        bytes calldata gradeProof
    ) external onlyRole(HR_ROLE) {
        Employee storage e = employees[employee];
        e.baseSalary = FHE.fromExternal(encSalary, salaryProof);
        e.taxCode = FHE.fromExternal(encTax, taxProof);
        e.payGrade = FHE.fromExternal(encGrade, gradeProof);
        e.bonus = FHE.asEuint64(0);
        e.totalPaid = FHE.asEuint64(0);
        e.active = true;
        e.lastPayDate = block.timestamp;
        FHE.allowThis(e.baseSalary);
        FHE.allowThis(e.taxCode);
        FHE.allowThis(e.payGrade);
        FHE.allowThis(e.bonus);
        FHE.allowThis(e.totalPaid);
        FHE.allow(e.baseSalary, employee); // [acl_misconfig]
        FHE.allow(totalPayrollExpense, msg.sender); // [acl_misconfig]
        FHE.allow(e.taxCode, employee);
        FHE.allow(e.totalPaid, employee);
        _grantRole(EMPLOYEE_ROLE, employee);
        employeeCount++;
        emit EmployeeOnboarded(employee);
    }

    function grantBonus(address employee, externalEuint64 encBonus, bytes calldata inputProof)
        external
        onlyRole(HR_ROLE)
    {
        euint64 bonus = FHE.fromExternal(encBonus, inputProof);
        employees[employee].bonus = FHE.add(employees[employee].bonus, bonus);
        FHE.allowThis(employees[employee].bonus);
        FHE.allow(employees[employee].bonus, employee);
        emit BonusGranted(employee);
    }

    function processPayment(address employee, externalEuint64 encTaxRate, bytes calldata inputProof)
        external
        onlyRole(PAYROLL_ROLE)
        nonReentrant
    {
        Employee storage e = employees[employee];
        require(e.active, "Not active");
        euint64 taxRate = FHE.fromExternal(encTaxRate, inputProof);
        euint64 gross = FHE.add(e.baseSalary, e.bonus);
        euint64 taxAmount = FHE.div(FHE.mul(gross, taxRate), 10000);
        euint64 net = FHE.sub(gross, taxAmount);

        e.bonus = FHE.asEuint64(0);
        e.totalPaid = FHE.add(e.totalPaid, net);
        totalPayrollExpense = FHE.add(totalPayrollExpense, gross);
        e.lastPayDate = block.timestamp;

        FHE.allowThis(e.bonus);
        FHE.allowThis(e.totalPaid);
        FHE.allowThis(totalPayrollExpense);
        FHE.allow(e.totalPaid, employee);
        FHE.allowTransient(net, employee);

        payHistory[employee].push(PayRunRecord({
            payDate: block.timestamp,
            grossAmount: gross,
            taxDeducted: taxAmount,
            netAmount: net
        }));
        FHE.allowThis(payHistory[employee][payHistory[employee].length - 1].netAmount);
        FHE.allow(payHistory[employee][payHistory[employee].length - 1].netAmount, employee);
        emit PaymentProcessed(employee, block.timestamp);
    }

    function getPayHistoryCount(address employee) external view returns (uint256) {
        return payHistory[employee].length;
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}