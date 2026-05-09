// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedPayroll_b11_003 is ZamaEthereumConfig {
    address public employer;
    euint64 private totalBudget;
    mapping(address => euint64) private salaries;

    constructor() {
        employer = msg.sender;
        totalBudget = FHE.asEuint64(0);
        FHE.allowThis(totalBudget);
    }

    function setSalary(address employee, externalEuint64 salaryStr, bytes calldata proof) public {
        require(msg.sender == employer, "Not employer");
        euint64 newSalary = FHE.fromExternal(salaryStr, proof);
        totalBudget = FHE.add(totalBudget, newSalary);
        salaries[employee] = newSalary;
        
        FHE.allowThis(salaries[employee]);
        FHE.allowThis(totalBudget);
    }
}
