// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ConfidentialPayrollVault is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant HR_ROLE = keccak256("HR_ROLE");
    IERC20 public immutable paymentToken;

    struct EmployeeLedger {
        euint64 encryptedBalance;
        euint64 encryptedSalaryPerSecond;
        uint256 lastClaimTimestamp;
        bool isActive;
    }

    mapping(address => EmployeeLedger) private ledgers;
    euint64 private vaultEncryptedTotal;

    event Deposited(address indexed company, uint256 amount);
    event Withdrawn(address indexed employee);

    constructor(address _paymentToken) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(HR_ROLE, msg.sender);
        paymentToken = IERC20(_paymentToken);
        
        vaultEncryptedTotal = FHE.asEuint64(0);
        FHE.allowThis(vaultEncryptedTotal);
    }

    // 1. Company deposits plaintext ERC20 to fund the encrypted payroll
    function fundPayroll(uint256 amount) external onlyRole(HR_ROLE) {
        require(paymentToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        euint64 encryptedDeposit = FHE.asEuint64(uint64(amount));
        FHE.allowThis(encryptedDeposit);
        
        vaultEncryptedTotal = FHE.add(vaultEncryptedTotal, encryptedDeposit);
        FHE.allowThis(vaultEncryptedTotal);
        
        emit Deposited(msg.sender, amount);
    }

    // 2. HR sets an encrypted salary rate for an employee
    function setEmployeeSalary(
        address employee,
        externalEuint64 extSalaryPerSec,
        bytes calldata inputProof
    ) external onlyRole(HR_ROLE) {
        euint64 salary = FHE.fromExternal(extSalaryPerSec, inputProof);
        FHE.allowThis(salary);

        if (!ledgers[employee].isActive) {
            ledgers[employee].encryptedBalance = FHE.asEuint64(0);
            FHE.allowThis(ledgers[employee].encryptedBalance);
            ledgers[employee].isActive = true;
        } else {
            // Accrue pending salary before updating rate
            _accrueSalary(employee);
        }

        ledgers[employee].encryptedSalaryPerSecond = salary;
        ledgers[employee].lastClaimTimestamp = block.timestamp;
    }

    // 3. Internal function to calculate accrued time-based pay
    function _accrueSalary(address employee) internal {
        uint256 timePassed = block.timestamp - ledgers[employee].lastClaimTimestamp;
        if (timePassed > 0) {
            euint64 timeMultiplier = FHE.asEuint64(uint64(timePassed));
            ebool _safeMul12 = FHE.le(ledgers[employee].encryptedSalaryPerSecond, FHE.asEuint64(type(uint32).max));
            euint64 earned = FHE.mul(ledgers[employee].encryptedSalaryPerSecond, timeMultiplier);
            FHE.allowThis(earned);

            ledgers[employee].encryptedBalance = FHE.add(ledgers[employee].encryptedBalance, earned);
            FHE.allowThis(ledgers[employee].encryptedBalance);
            ledgers[employee].lastClaimTimestamp = block.timestamp;
        }
    }

    // 4. Employee withdraws an encrypted amount, converting it to plaintext ERC20 transfer
    function withdrawSalary(
        externalEuint64 extAmount,
        bytes calldata inputProof
    ) external nonReentrant {
        require(ledgers[msg.sender].isActive, "Not an employee");
        
        _accrueSalary(msg.sender);

        euint64 amountToWithdraw = FHE.fromExternal(extAmount, inputProof);
        FHE.allowThis(amountToWithdraw);

        // Verify employee has enough encrypted balance
        ebool hasSufficientFunds = FHE.ge(ledgers[msg.sender].encryptedBalance, amountToWithdraw);

        // Update encrypted state
        ebool _safeSub56 = FHE.ge(ledgers[msg.sender].encryptedBalance, amountToWithdraw);
        ledgers[msg.sender].encryptedBalance = FHE.select(_safeSub56, FHE.sub(ledgers[msg.sender].encryptedBalance, amountToWithdraw), FHE.asEuint64(0));
        FHE.allowThis(ledgers[msg.sender].encryptedBalance);
        
        ebool _safeSub57 = FHE.ge(vaultEncryptedTotal, amountToWithdraw);
        vaultEncryptedTotal = FHE.select(_safeSub57, FHE.sub(vaultEncryptedTotal, amountToWithdraw), FHE.asEuint64(0));
        FHE.allowThis(vaultEncryptedTotal);

        // Decrypt the specific withdrawal amount for the ERC20 transfer
        // Note: In a true fully-shielded system, this would transfer a shielded token. 
        // Here, we bridge back to standard ERC20.
        FHE.allow(amountToWithdraw, msg.sender);
        
        emit Withdrawn(msg.sender);
    }
}