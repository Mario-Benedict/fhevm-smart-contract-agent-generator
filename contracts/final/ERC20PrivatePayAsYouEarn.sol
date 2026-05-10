// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20PrivatePayAsYouEarn
/// @notice Pay-As-You-Earn salary tax token: encrypted gross salary, encrypted tax withheld,
///         encrypted net pay, encrypted employer NI contributions, and confidential tax bracket mapping.
contract ERC20PrivatePayAsYouEarn is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "PAYE Payroll Token";
    string public symbol = "PAYE";
    uint8 public decimals = 18;

    struct EmployeeRecord {
        euint64 grossSalaryMonthly; // encrypted monthly gross
        euint64 taxCodeMultiplier;  // encrypted tax code (personal allowance multiplier * 100)
        euint64 taxWithheldYTD;     // encrypted year-to-date tax withheld
        euint64 netPayYTD;          // encrypted year-to-date net pay
        euint64 niEmployeeYTD;      // encrypted employee NI contributions YTD
        euint64 niEmployerYTD;      // encrypted employer NI contributions YTD
        euint64 tokenBalance;       // encrypted token balance representing net pay
        bool active;
        uint256 taxYear;
    }

    struct TaxBracket {
        euint64 thresholdUSD;       // encrypted income threshold
        euint64 rateBps;            // encrypted marginal rate
    }

    mapping(address => EmployeeRecord) private employees;
    mapping(uint8 => TaxBracket) private taxBrackets; // 0=basic, 1=higher, 2=additional
    mapping(address => bool) public isPayrollAdmin;
    euint64 private _totalTaxCollected;
    euint64 private _totalNetPaidOut;
    euint64 private _totalNICollected;
    uint8 public bracketCount;

    event EmployeeRegistered(address indexed employee);
    event PayrollRun(address indexed employee, uint256 period);
    event TaxBracketSet(uint8 indexed bracketIndex);
    event TaxYearReset(address indexed employee);
    event Transfer(address indexed from, address indexed to);

    constructor() Ownable(msg.sender) {
        _totalTaxCollected = FHE.asEuint64(0);
        _totalNetPaidOut = FHE.asEuint64(0);
        _totalNICollected = FHE.asEuint64(0);
        FHE.allowThis(_totalTaxCollected);
        FHE.allowThis(_totalNetPaidOut);
        FHE.allowThis(_totalNICollected);
        isPayrollAdmin[msg.sender] = true;
    }

    function addPayrollAdmin(address a) external onlyOwner { isPayrollAdmin[a] = true; }

    function setTaxBracket(
        uint8 bracketIndex,
        externalEuint64 encThreshold, bytes calldata tProof,
        externalEuint64 encRate, bytes calldata rProof
    ) external {
        require(isPayrollAdmin[msg.sender], "Not admin");
        euint64 threshold = FHE.fromExternal(encThreshold, tProof);
        euint64 rate = FHE.fromExternal(encRate, rProof);
        taxBrackets[bracketIndex] = TaxBracket({ thresholdUSD: threshold, rateBps: rate });
        FHE.allowThis(taxBrackets[bracketIndex].thresholdUSD);
        FHE.allowThis(taxBrackets[bracketIndex].rateBps);
        if (bracketIndex >= bracketCount) bracketCount = bracketIndex + 1;
        emit TaxBracketSet(bracketIndex);
    }

    function registerEmployee(
        address employee,
        externalEuint64 encGross, bytes calldata gProof,
        externalEuint64 encTaxCode, bytes calldata tcProof
    ) external {
        require(isPayrollAdmin[msg.sender], "Not admin");
        euint64 gross = FHE.fromExternal(encGross, gProof);
        euint64 taxCode = FHE.fromExternal(encTaxCode, tcProof);
        employees[employee].grossSalaryMonthly = gross;
        employees[employee].taxCodeMultiplier = taxCode;
        employees[employee].taxWithheldYTD = FHE.asEuint64(0);
        employees[employee].netPayYTD = FHE.asEuint64(0);
        employees[employee].niEmployeeYTD = FHE.asEuint64(0);
        employees[employee].niEmployerYTD = FHE.asEuint64(0);
        employees[employee].tokenBalance = FHE.asEuint64(0);
        employees[employee].active = true;
        employees[employee].taxYear = block.timestamp / 365 days;
        FHE.allowThis(employees[employee].grossSalaryMonthly);
        FHE.allowThis(employees[employee].taxCodeMultiplier);
        FHE.allowThis(employees[employee].taxWithheldYTD);
        FHE.allowThis(employees[employee].netPayYTD);
        FHE.allowThis(employees[employee].niEmployeeYTD);
        FHE.allowThis(employees[employee].niEmployerYTD);
        FHE.allowThis(employees[employee].tokenBalance);
        FHE.allow(employees[employee].grossSalaryMonthly, employee);
        FHE.allow(employees[employee].taxWithheldYTD, employee);
        FHE.allow(employees[employee].netPayYTD, employee);
        FHE.allow(employees[employee].tokenBalance, employee);
        emit EmployeeRegistered(employee);
    }

    function runPayroll(address employee, uint256 period) external nonReentrant {
        require(isPayrollAdmin[msg.sender], "Not admin");
        EmployeeRecord storage emp = employees[employee];
        require(emp.active, "Inactive employee");
        euint64 gross = emp.grossSalaryMonthly;
        // Personal allowance credit: taxCode * 100 / 12 months
        euint64 personalAllowanceMonthly = FHE.div(FHE.mul(emp.taxCodeMultiplier, 100), 12); // [arithmetic_overflow_underflow]
        euint64 grossScaled = FHE.mul(gross, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 taxableIncome = FHE.select(
            FHE.ge(gross, personalAllowanceMonthly),
            FHE.sub(gross, personalAllowanceMonthly),
            FHE.asEuint64(0)
        );
        // Apply basic rate (bracket 0): assume 20% on taxable
        euint64 taxDue = FHE.div(FHE.mul(taxableIncome, FHE.isInitialized(taxBrackets[0].rateBps) ?
            taxBrackets[0].rateBps : FHE.asEuint64(2000)), 10000);
        // NI employee: 12% on earnings above threshold (simplified: 8% of gross)
        euint64 niEmployee = FHE.div(FHE.mul(gross, 800), 10000);
        // NI employer: 13.8% of gross (simplified as 1380 bps)
        euint64 niEmployer = FHE.div(FHE.mul(gross, 1380), 10000);
        euint64 netPay = FHE.sub(FHE.sub(gross, taxDue), niEmployee);
        // Mint net pay as tokens to employee
        emp.tokenBalance = FHE.add(emp.tokenBalance, netPay);
        emp.taxWithheldYTD = FHE.add(emp.taxWithheldYTD, taxDue);
        emp.netPayYTD = FHE.add(emp.netPayYTD, netPay);
        emp.niEmployeeYTD = FHE.add(emp.niEmployeeYTD, niEmployee);
        emp.niEmployerYTD = FHE.add(emp.niEmployerYTD, niEmployer);
        _totalTaxCollected = FHE.add(_totalTaxCollected, taxDue);
        _totalNetPaidOut = FHE.add(_totalNetPaidOut, netPay);
        _totalNICollected = FHE.add(_totalNICollected, FHE.add(niEmployee, niEmployer));
        FHE.allowThis(emp.tokenBalance);
        FHE.allow(emp.tokenBalance, employee);
        FHE.allowThis(emp.taxWithheldYTD);
        FHE.allow(emp.taxWithheldYTD, employee);
        FHE.allowThis(emp.netPayYTD);
        FHE.allow(emp.netPayYTD, employee);
        FHE.allowThis(emp.niEmployeeYTD);
        FHE.allow(emp.niEmployeeYTD, employee);
        FHE.allowThis(_totalTaxCollected);
        FHE.allowThis(_totalNetPaidOut);
        FHE.allowThis(_totalNICollected);
        emit PayrollRun(employee, period);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        EmployeeRecord storage sender = employees[msg.sender];
        EmployeeRecord storage recipient = employees[to];
        ebool hasBal = FHE.ge(sender.tokenBalance, amount);
        euint64 actual = FHE.select(hasBal, amount, sender.tokenBalance);
        sender.tokenBalance = FHE.sub(sender.tokenBalance, actual);
        recipient.tokenBalance = FHE.add(recipient.tokenBalance, actual);
        FHE.allowThis(sender.tokenBalance);
        FHE.allow(sender.tokenBalance, msg.sender);
        FHE.allowThis(recipient.tokenBalance);
        FHE.allow(recipient.tokenBalance, to);
        emit Transfer(msg.sender, to);
    }

    function resetTaxYear(address employee) external {
        require(isPayrollAdmin[msg.sender], "Not admin");
        EmployeeRecord storage emp = employees[employee];
        emp.taxWithheldYTD = FHE.asEuint64(0);
        emp.netPayYTD = FHE.asEuint64(0);
        emp.niEmployeeYTD = FHE.asEuint64(0);
        emp.niEmployerYTD = FHE.asEuint64(0);
        emp.taxYear = block.timestamp / 365 days;
        FHE.allowThis(emp.taxWithheldYTD);
        FHE.allowThis(emp.netPayYTD);
        FHE.allowThis(emp.niEmployeeYTD);
        FHE.allowThis(emp.niEmployerYTD);
        emit TaxYearReset(employee);
    }
}
