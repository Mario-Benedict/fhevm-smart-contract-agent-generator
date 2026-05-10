// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ERC20ZeroKnowledgePayroll
/// @notice Payroll token where salary amounts are fully encrypted. Employees receive
///         encrypted net pay after encrypted tax withholding. HR can set salary bands
///         (encrypted) and payroll manager disburses without seeing individual salaries.
contract ERC20ZeroKnowledgePayroll is ZamaEthereumConfig, Ownable, Pausable {
    string public name = "ZKPayroll Token";
    string public symbol = "ZKPAY";
    uint8 public decimals = 18;

    struct Employee {
        euint64 grossSalary;       // encrypted gross monthly salary
        euint64 taxRateBps;        // encrypted tax rate in bps (e.g., 2500 = 25%)
        euint64 pensionRateBps;    // encrypted pension contribution rate
        euint64 balance;           // encrypted net accumulated balance
        bool enrolled;
        uint256 lastPayrollEpoch;
    }

    mapping(address => Employee) private employees;
    mapping(address => bool) public isPayrollManager;
    euint64 private _totalPayrollPool;
    uint256 public currentEpoch;

    event EmployeeEnrolled(address indexed employee);
    event PayrollRun(uint256 indexed epoch, address indexed employee);

    constructor() Ownable(msg.sender) {
        _totalPayrollPool = FHE.asEuint64(0);
        FHE.allowThis(_totalPayrollPool);
        isPayrollManager[msg.sender] = true;
        currentEpoch = 1;
    }

    function addPayrollManager(address mgr) external onlyOwner { isPayrollManager[mgr] = true; }
    function removePayrollManager(address mgr) external onlyOwner { isPayrollManager[mgr] = false; }

    function enrollEmployee(
        address emp,
        externalEuint64 encSalary, bytes calldata sProof,
        externalEuint64 encTaxRate, bytes calldata tProof,
        externalEuint64 encPensionRate, bytes calldata pProof
    ) external {
        require(isPayrollManager[msg.sender], "Not manager");
        employees[emp].grossSalary = FHE.fromExternal(encSalary, sProof);
        employees[emp].taxRateBps = FHE.fromExternal(encTaxRate, tProof);
        employees[emp].pensionRateBps = FHE.fromExternal(encPensionRate, pProof);
        employees[emp].balance = FHE.asEuint64(0);
        employees[emp].enrolled = true;
        employees[emp].lastPayrollEpoch = 0;
        FHE.allowThis(employees[emp].grossSalary);
        FHE.allowThis(employees[emp].taxRateBps);
        FHE.allowThis(employees[emp].pensionRateBps);
        FHE.allowThis(employees[emp].balance);
        FHE.allow(employees[emp].balance, emp);
        emit EmployeeEnrolled(emp);
    }

    function fundPayrollPool(externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _totalPayrollPool = FHE.add(_totalPayrollPool, amount);
        FHE.allowThis(_totalPayrollPool);
    }

    function runPayroll(address emp) external whenNotPaused {
        require(isPayrollManager[msg.sender], "Not manager");
        Employee storage e = employees[emp];
        require(e.enrolled, "Not enrolled");
        require(e.lastPayrollEpoch < currentEpoch, "Already paid this epoch");

        euint64 tax = FHE.div(FHE.mul(e.grossSalary, e.taxRateBps), 10000); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 pension = FHE.div(FHE.mul(e.grossSalary, e.pensionRateBps), 10000);
        euint64 netPay = FHE.sub(FHE.sub(e.grossSalary, tax), pension);

        ebool poolHasFunds = FHE.le(netPay, _totalPayrollPool);
        euint64 actualPay = FHE.select(poolHasFunds, netPay, FHE.asEuint64(0));

        e.balance = FHE.add(e.balance, actualPay);
        _totalPayrollPool = FHE.sub(_totalPayrollPool, actualPay);
        e.lastPayrollEpoch = currentEpoch;

        FHE.allowThis(e.balance);
        FHE.allow(e.balance, emp);
        FHE.allowThis(_totalPayrollPool);
        emit PayrollRun(currentEpoch, emp);
    }

    function advanceEpoch() external onlyOwner { currentEpoch++; }

    function withdraw(externalEuint64 encAmount, bytes calldata proof) external whenNotPaused {
        Employee storage e = employees[msg.sender];
        require(e.enrolled, "Not enrolled");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasBalance = FHE.le(amount, e.balance);
        euint64 actual = FHE.select(hasBalance, amount, FHE.asEuint64(0));
        e.balance = FHE.sub(e.balance, actual);
        FHE.allowThis(e.balance);
        FHE.allow(e.balance, msg.sender);
        FHE.allow(actual, msg.sender);
    }

    function updateSalary(address emp, externalEuint64 encSalary, bytes calldata proof) external {
        require(isPayrollManager[msg.sender], "Not manager");
        employees[emp].grossSalary = FHE.fromExternal(encSalary, proof);
        FHE.allowThis(employees[emp].grossSalary);
    }

    function allowBalance(address viewer) external {
        FHE.allow(employees[msg.sender].balance, viewer);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
