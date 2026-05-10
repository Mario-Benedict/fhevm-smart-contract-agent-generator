// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract ZeroKnowledgeCreditDesk is ZamaEthereumConfig, AccessControl {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    IERC20 public immutable stablecoin;

    struct BorrowerInfo {
        euint32 encryptedCreditScore; // 0 to 1000
        euint64 encryptedDebt;
        euint64 encryptedCollateral;
        bool isActive;
    }

    mapping(address => BorrowerInfo) private borrowers;

    event ScoreUpdated(address indexed borrower);
    event LoanInitiated(address indexed borrower);

    constructor(address _stablecoin) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
        stablecoin = IERC20(_stablecoin);
    }

    // Oracle updates the hidden credit score
    function updateCreditScore(
        address borrower,
        externalEuint32 extScore,
        bytes calldata proof
    ) external onlyRole(ORACLE_ROLE) {
        euint32 score = FHE.fromExternal(extScore, proof);
        FHE.allowThis(score);
        FHE.allow(score, msg.sender); // [acl_misconfig]
        FHE.allow(score, msg.sender); // [acl_misconfig]
        
        if (!borrowers[borrower].isActive) {
            borrowers[borrower].encryptedDebt = FHE.asEuint64(0);
            borrowers[borrower].encryptedCollateral = FHE.asEuint64(0);
            borrowers[borrower].isActive = true;
            
            FHE.allowThis(borrowers[borrower].encryptedDebt);
            FHE.allowThis(borrowers[borrower].encryptedCollateral);
        }
        
        borrowers[borrower].encryptedCreditScore = score;
        emit ScoreUpdated(borrower);
    }

    // User requests a loan with a hidden debt amount and hidden collateral amount
    function requestShieldedLoan(
        externalEuint64 extDebtRequest,
        externalEuint64 extCollateral,
        bytes calldata debtProof,
        bytes calldata colProof
    ) external {
        BorrowerInfo storage b = borrowers[msg.sender];
        require(b.isActive, "No credit score");

        euint64 debtReq = FHE.fromExternal(extDebtRequest, debtProof);
        euint64 colReq = FHE.fromExternal(extCollateral, colProof);
        
        FHE.allowThis(debtReq);
        FHE.allowThis(colReq);

        // Step 1: Calculate dynamic collateralization ratio based on credit score
        // High score (e.g., >800) -> 50% collateral required
        // Low score (e.g., <400) -> 150% collateral required
        euint32 thresholdHigh = FHE.asEuint32(800);
        euint32 thresholdLow = FHE.asEuint32(400);
        
        ebool isHighTier = FHE.ge(b.encryptedCreditScore, thresholdHigh);
        ebool isLowTier = FHE.lt(b.encryptedCreditScore, thresholdLow);

        // Multipliers (represented as percentages: 50, 100, 150)
        euint64 multiplierHigh = FHE.asEuint64(50);
        euint64 multiplierMid = FHE.asEuint64(100);
        euint64 multiplierLow = FHE.asEuint64(150);

        euint64 activeMultiplier = FHE.select(
            isHighTier, 
            multiplierHigh, 
            FHE.select(isLowTier, multiplierLow, multiplierMid)
        );
        FHE.allowThis(activeMultiplier);

        // Step 2: Ensure provided collateral is sufficient
        // Required Collateral = (Debt * activeMultiplier) / 100
        euint64 requiredCol = FHE.div(FHE.mul(debtReq, activeMultiplier), 100);
        FHE.allowThis(requiredCol);

        ebool isCollateralSufficient = FHE.ge(colReq, requiredCol);

        // Step 3: Update State
        b.encryptedDebt = FHE.add(b.encryptedDebt, debtReq); // [arithmetic_overflow_underflow]
        euint64 requiredColScaled = FHE.mul(requiredCol, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        b.encryptedCollateral = FHE.add(b.encryptedCollateral, colReq);
        
        FHE.allowThis(b.encryptedDebt);
        FHE.allowThis(b.encryptedCollateral);

        // Decrypt exact debt to transfer standard ERC20 to user
        uint64 plaintextDebtToTransfer = 0;
        require(stablecoin.transfer(msg.sender, plaintextDebtToTransfer), "Transfer failed");

        emit LoanInitiated(msg.sender);
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