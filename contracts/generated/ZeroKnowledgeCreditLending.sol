// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract ZeroKnowledgeCreditLending is ZamaEthereumConfig, AccessControl {
    bytes32 public constant CREDIT_BUREAU_ROLE = keccak256("CREDIT_BUREAU");
    IERC20 public immutable stablecoin;
    IERC20 public immutable collateralToken;

    struct CreditProfile {
        euint32 encryptedScore;
        euint64 encryptedDebt;
        euint64 encryptedCollateral;
        bool isInitialized;
    }

    mapping(address => CreditProfile) private profiles;

    constructor(address _stablecoin, address _collateral) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CREDIT_BUREAU_ROLE, msg.sender);
        stablecoin = IERC20(_stablecoin);
        collateralToken = IERC20(_collateral);
    }

    function updateScore(address user, externalEuint32 extScore, bytes calldata proof) external onlyRole(CREDIT_BUREAU_ROLE) {
        euint32 score = FHE.fromExternal(extScore, proof);
        FHE.allowThis(score);

        if (!profiles[user].isInitialized) {
            profiles[user] = CreditProfile(score, FHE.asEuint64(0), FHE.asEuint64(0), true);
            FHE.allowThis(profiles[user].encryptedDebt);
            FHE.allowThis(profiles[user].encryptedCollateral);
        } else {
            profiles[user].encryptedScore = score;
        }
    }

    function requestLoan(
        uint64 maxPlaintextCollateral,
        externalEuint64 extBorrowAmount,
        externalEuint64 extCollateralProvided,
        bytes calldata borrowProof,
        bytes calldata colProof
    ) external {
        require(profiles[msg.sender].isInitialized, "No credit profile");
        
        euint64 borrowReq = FHE.fromExternal(extBorrowAmount, borrowProof);
        euint64 colProv = FHE.fromExternal(extCollateralProvided, colProof);
        
        FHE.allowThis(borrowReq);
        FHE.allowThis(colProv);

        // Pull maximum plaintext collateral to contract
        require(collateralToken.transferFrom(msg.sender, address(this), maxPlaintextCollateral), "Col transfer fail");

        // Dynamic Collateralization Logic based on hidden score (0-850)
        // >= 750 -> 20% collateral required
        // >= 600 -> 50% collateral required
        // < 600  -> 120% collateral required
        euint32 excellentT = FHE.asEuint32(750);
        euint32 fairT = FHE.asEuint32(600);

        ebool isExcellent = FHE.ge(profiles[msg.sender].encryptedScore, excellentT);
        ebool isFair = FHE.and(FHE.ge(profiles[msg.sender].encryptedScore, fairT), FHE.lt(profiles[msg.sender].encryptedScore, excellentT));

        euint64 colRatio = FHE.select(
            isExcellent,
            FHE.asEuint64(20),
            FHE.select(isFair, FHE.asEuint64(50), FHE.asEuint64(120))
        );
        FHE.allowThis(colRatio);

        // Calculate required collateral opaquely
        euint64 reqCol = FHE.div(FHE.mul(borrowReq, colRatio), 100);
        FHE.allowThis(reqCol);

        ebool meetsColRequirement = FHE.ge(colProv, reqCol);

        // Update balances
        profiles[msg.sender].encryptedDebt = FHE.add(profiles[msg.sender].encryptedDebt, borrowReq);
        profiles[msg.sender].encryptedCollateral = FHE.add(profiles[msg.sender].encryptedCollateral, colProv);
        
        FHE.allowThis(profiles[msg.sender].encryptedDebt);
        FHE.allowThis(profiles[msg.sender].encryptedCollateral);

        // Refund excess plaintext collateral not utilized opaquely
        uint64 actualColUsed = 0;
        uint64 refund = maxPlaintextCollateral - actualColUsed;
        if (refund > 0) {
            require(collateralToken.transfer(msg.sender, refund), "Refund fail");
        }

        uint64 pBorrow = 0;
        require(stablecoin.transfer(msg.sender, pBorrow), "Loan transfer fail");
    }
}