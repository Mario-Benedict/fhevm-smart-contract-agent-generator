// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSalaryPayrollSystem
/// @notice Encrypted payroll system: hidden employee salaries, private deduction amounts,
///         confidential tax withholding, and encrypted payslip generation without revealing
///         salary data to unauthorized parties.
contract PrivateSalaryPayrollSystem is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum EmploymentType { FullTime, PartTime, Contractor, Intern }

    struct Employee {
        address wallet;
        EmploymentType employmentType;
        string employeeRef;
        euint64 grossSalaryUSD;        // encrypted gross salary
        euint64 taxWithholdingBps;     // encrypted tax rate
        euint64 deductionsUSD;         // encrypted deductions
        euint64 netSalaryUSD;          // encrypted net pay
        euint64 totalPaidUSD;          // encrypted cumulative paid
        euint16 performanceScore;      // encrypted performance rating
        bool active;
    }

    struct PayrollRun {
        uint256 runId;
        uint256 period;                // payroll period (e.g. month number)
        euint64 totalGrossUSD;         // encrypted total gross
        euint64 totalNetUSD;           // encrypted total net paid
        euint64 totalTaxUSD;           // encrypted total tax withheld
        uint256 executedAt;
    }

    mapping(uint256 => Employee) private employees;
    mapping(address => uint256) private employeeIdByWallet;
    mapping(uint256 => PayrollRun) private payrollRuns;
    mapping(address => bool) public isHRManager;

    uint256 public employeeCount;
    uint256 public payrollRunCount;
    euint64 private _totalPayrollExpenseUSD;
    euint64 private _totalTaxRemittedUSD;

    event EmployeeOnboarded(uint256 indexed id, EmploymentType empType);
    event PayrollExecuted(uint256 indexed runId, uint256 period);
    event SalaryUpdated(uint256 indexed employeeId);

    modifier onlyHRManager() {
        require(isHRManager[msg.sender] || msg.sender == owner(), "Not HR manager");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPayrollExpenseUSD = FHE.asEuint64(0);
        _totalTaxRemittedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalPayrollExpenseUSD);
        FHE.allowThis(_totalTaxRemittedUSD);
        isHRManager[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addHRManager(address hrm) external onlyOwner { isHRManager[hrm] = true; }

    function onboardEmployee(
        address wallet, EmploymentType empType, string calldata employeeRef,
        externalEuint64 encGross, bytes calldata gProof,
        externalEuint64 encTaxRate, bytes calldata tProof,
        externalEuint64 encDeductions, bytes calldata dProof,
        externalEuint16 encPerformance, bytes calldata pProof
    ) external onlyHRManager returns (uint256 id) {
        euint64 gross      = FHE.fromExternal(encGross, gProof);
        euint64 taxRate    = FHE.fromExternal(encTaxRate, tProof);
        euint64 deductions = FHE.fromExternal(encDeductions, dProof);
        euint16 performance= FHE.fromExternal(encPerformance, pProof);
        euint64 taxAmt     = FHE.div(FHE.mul(gross, taxRate), 10000);
        euint64 net        = FHE.sub(FHE.sub(gross, taxAmt), deductions);
        id = employeeCount++;
        employeeIdByWallet[wallet] = id;
        employees[id].wallet = wallet;
        employees[id].employmentType = empType;
        employees[id].employeeRef = employeeRef;
        employees[id].grossSalaryUSD = gross;
        employees[id].taxWithholdingBps = taxRate;
        employees[id].deductionsUSD = deductions;
        employees[id].netSalaryUSD = net;
        employees[id].totalPaidUSD = FHE.asEuint64(0);
        employees[id].performanceScore = performance;
        employees[id].active = true;
        FHE.allowThis(employees[id].grossSalaryUSD); FHE.allow(employees[id].grossSalaryUSD, wallet);
        FHE.allowThis(employees[id].taxWithholdingBps); FHE.allow(employees[id].taxWithholdingBps, wallet);
        FHE.allowThis(employees[id].deductionsUSD); FHE.allow(employees[id].deductionsUSD, wallet);
        FHE.allowThis(employees[id].netSalaryUSD); FHE.allow(employees[id].netSalaryUSD, wallet);
        FHE.allowThis(employees[id].totalPaidUSD); FHE.allow(employees[id].totalPaidUSD, wallet);
        FHE.allowThis(employees[id].performanceScore);
        emit EmployeeOnboarded(id, empType);
    }

    function runPayroll(uint256 period, uint256[] calldata employeeIds) external onlyHRManager whenNotPaused nonReentrant returns (uint256 runId) {
        euint64 totalGross = FHE.asEuint64(0);
        euint64 totalNet   = FHE.asEuint64(0);
        euint64 totalTax   = FHE.asEuint64(0);
        for (uint256 i = 0; i < employeeIds.length; i++) {
            Employee storage e = employees[employeeIds[i]];
            if (!e.active) continue;
            euint64 taxAmt = FHE.div(FHE.mul(e.grossSalaryUSD, e.taxWithholdingBps), 10000);
            totalGross = FHE.add(totalGross, e.grossSalaryUSD);
            totalNet   = FHE.add(totalNet, e.netSalaryUSD);
            totalTax   = FHE.add(totalTax, taxAmt);
            e.totalPaidUSD = FHE.add(e.totalPaidUSD, e.netSalaryUSD);
            FHE.allowThis(e.totalPaidUSD); FHE.allow(e.totalPaidUSD, e.wallet);
        }
        runId = payrollRunCount++;
        payrollRuns[runId] = PayrollRun({
            runId: runId, period: period, totalGrossUSD: totalGross,
            totalNetUSD: totalNet, totalTaxUSD: totalTax, executedAt: block.timestamp
        });
        _totalPayrollExpenseUSD = FHE.add(_totalPayrollExpenseUSD, totalNet);
        _totalTaxRemittedUSD    = FHE.add(_totalTaxRemittedUSD, totalTax);
        FHE.allowThis(payrollRuns[runId].totalGrossUSD); FHE.allow(payrollRuns[runId].totalGrossUSD, msg.sender);
        FHE.allowThis(payrollRuns[runId].totalNetUSD); FHE.allow(payrollRuns[runId].totalNetUSD, msg.sender);
        FHE.allowThis(payrollRuns[runId].totalTaxUSD); FHE.allow(payrollRuns[runId].totalTaxUSD, msg.sender);
        FHE.allowThis(_totalPayrollExpenseUSD); FHE.allowThis(_totalTaxRemittedUSD);
        emit PayrollExecuted(runId, period);
    }

    function allowPayrollStats(address viewer) external onlyOwner {
        FHE.allow(_totalPayrollExpenseUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalPayrollExpenseUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalTaxRemittedUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalTaxRemittedUSD, viewer);
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