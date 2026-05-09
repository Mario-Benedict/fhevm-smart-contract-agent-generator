// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract CorporateExpenseShield is ZamaEthereumConfig, AccessControl {
    bytes32 public constant FINANCE_ROLE = keccak256("FINANCE_ROLE");

    struct ExpenseAccount {
        euint64 encryptedAllowance;
        euint64 encryptedSpent;
        bool isInitialized;
    }

    mapping(address => ExpenseAccount) private accounts;
    mapping(address => mapping(address => euint64)) private merchantBalances;

    event AllowanceUpdated(address indexed employee);
    event ExpenseCharged(address indexed employee, address indexed merchant);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FINANCE_ROLE, msg.sender);
    }

    function setExpenseAllowance(
        address employee,
        externalEuint64 extLimit,
        bytes calldata inputProof
    ) external onlyRole(FINANCE_ROLE) {
        euint64 newLimit = FHE.fromExternal(extLimit, inputProof);
        FHE.allowThis(newLimit);

        if (!accounts[employee].isInitialized) {
            euint64 initialSpent = FHE.asEuint64(0);
            FHE.allowThis(initialSpent);
            
            accounts[employee] = ExpenseAccount({
                encryptedAllowance: newLimit,
                encryptedSpent: initialSpent,
                isInitialized: true
            });
        } else {
            // Top up existing limit
            accounts[employee].encryptedAllowance = FHE.add(accounts[employee].encryptedAllowance, newLimit);
            FHE.allowThis(accounts[employee].encryptedAllowance);
        }

        emit AllowanceUpdated(employee);
    }

    function chargeExpense(
        address merchant,
        externalEuint64 extChargeAmount,
        bytes calldata inputProof
    ) external {
        require(accounts[msg.sender].isInitialized, "No expense account");

        euint64 chargeAmount = FHE.fromExternal(extChargeAmount, inputProof);
        FHE.allowThis(chargeAmount);

        ExpenseAccount storage acc = accounts[msg.sender];

        // Ensure (Spent + Charge) <= Allowance
        euint64 proposedSpent = FHE.add(acc.encryptedSpent, chargeAmount);
        FHE.allowThis(proposedSpent);
        
        ebool withinBudget = FHE.le(proposedSpent, acc.encryptedAllowance);

        // Update employee spent amount
        acc.encryptedSpent = proposedSpent;

        // Initialize merchant balance if needed
        if (!FHE.isInitialized(merchantBalances[merchant][merchant])) {
             merchantBalances[merchant][merchant] = FHE.asEuint64(0);
             FHE.allowThis(merchantBalances[merchant][merchant]);
        }

        // Credit the merchant
        merchantBalances[merchant][merchant] = FHE.add(merchantBalances[merchant][merchant], chargeAmount);
        FHE.allowThis(merchantBalances[merchant][merchant]);

        emit ExpenseCharged(msg.sender, merchant);
    }

    function viewMyEncryptedAvailable(address employee) external view returns (euint64) {
        require(msg.sender == employee || hasRole(FINANCE_ROLE, msg.sender), "Unauthorized");
        ExpenseAccount storage acc = accounts[employee];
        return FHE.sub(acc.encryptedAllowance, acc.encryptedSpent);
    }
}