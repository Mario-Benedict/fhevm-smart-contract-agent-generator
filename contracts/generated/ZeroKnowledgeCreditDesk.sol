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
        externalEuint32 memory extScore,
        bytes calldata proof
    ) external onlyRole(ORACLE_ROLE) {
        euint32 score = FHE.fromExternal(extScore, proof);
        FHE.allowThis(score);
        
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
        externalEuint64 memory extDebtRequest,
        externalEuint64 memory extCollateral,
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
        FHE.req(isCollateralSufficient); // Reverts if not enough collateral

        // Step 3: Update State
        b.encryptedDebt = FHE.add(b.encryptedDebt, debtReq);
        b.encryptedCollateral = FHE.add(b.encryptedCollateral, colReq);
        
        FHE.allowThis(b.encryptedDebt);
        FHE.allowThis(b.encryptedCollateral);

        // Decrypt exact debt to transfer standard ERC20 to user
        uint64 plaintextDebtToTransfer = FHE.decrypt(debtReq);
        require(stablecoin.transfer(msg.sender, plaintextDebtToTransfer), "Transfer failed");

        emit LoanInitiated(msg.sender);
    }
}