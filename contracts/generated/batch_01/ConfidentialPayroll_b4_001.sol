// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ConfidentialPayroll_b4_001 is ZamaEthereumConfig {
    address public employer;
    
    struct Employee {
        euint64 salaryPerSecond;
        uint256 lastClaimTime;
        ebool isActive;
    }
    
    mapping(address => Employee) private employees;
    mapping(address => euint64) private balances;

    modifier onlyEmployer() {
        require(msg.sender == employer, "Not employer");
        _;
    }

    constructor() {
        employer = msg.sender;
    }

    function addEmployee(address employee, externalEuint64 salaryStr, bytes calldata proof) public onlyEmployer {
        euint64 salary = FHE.fromExternal(salaryStr, proof);
        employees[employee] = Employee({
            salaryPerSecond: salary,
            lastClaimTime: block.timestamp,
            isActive: FHE.asEbool(true)
        });
        FHE.allowThis(employees[employee].salaryPerSecond);
        FHE.allowThis(employees[employee].isActive);
    }

    function fundPayroll(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        balances[address(this)] = FHE.add(balances[address(this)], amount);
        FHE.allowThis(balances[address(this)]);
    }

    function claimSalary() public {
        Employee storage emp = employees[msg.sender];
        require(emp.lastClaimTime > 0, "Not an employee");
        
        uint256 timeElapsed = block.timestamp - emp.lastClaimTime;
        
        // Calculate owed: salaryPerSecond * timeElapsed
        euint64 owed = FHE.mul(emp.salaryPerSecond, FHE.asEuint64(uint64(timeElapsed)));
        euint64 actualOwed = FHE.select(emp.isActive, owed, FHE.asEuint64(0));

        // Check if contract has enough funds
        euint64 poolBalance = balances[address(this)];
        ebool canPay = FHE.le(actualOwed, poolBalance);
        
        euint64 payout = FHE.select(canPay, actualOwed, FHE.asEuint64(0));
        
        // Update balances
        balances[address(this)] = FHE.sub(poolBalance, payout);
        balances[msg.sender] = FHE.add(balances[msg.sender], payout);
        
        emp.lastClaimTime = block.timestamp;
        
        FHE.allowThis(balances[address(this)]);
        FHE.allowThis(balances[msg.sender]);
    }
}
