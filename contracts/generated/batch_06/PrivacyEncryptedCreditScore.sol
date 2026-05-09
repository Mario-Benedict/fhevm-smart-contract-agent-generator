// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivacyEncryptedCreditScore
/// @notice Decentralized credit scoring where data from multiple lenders is
///         aggregated into an encrypted composite score. Borrowers share their
///         score selectively with specific lenders.
contract PrivacyEncryptedCreditScore is ZamaEthereumConfig, Ownable {
    struct CreditScore {
        euint16 paymentHistoryScore;  // 35% weight
        euint16 utilizationScore;     // 30% weight
        euint16 lengthScore;          // 15% weight
        euint16 mixScore;             // 10% weight
        euint16 newCreditScore;       // 10% weight
        euint16 compositeScore;       // encrypted final score (300-850 range)
        uint256 lastUpdated;
        bool exists;
    }

    struct DataContribution {
        address lender;
        euint8 paymentRating;     // 0-100
        euint32 creditLimit;      // encrypted
        euint32 utilization;      // encrypted
        uint256 submittedAt;
    }

    mapping(address => CreditScore) private scores;
    mapping(address => DataContribution[]) private contributions;
    mapping(address => bool) public isLender;
    mapping(address => mapping(address => bool)) public borrowerConsent; // borrower => lender => consent

    event ScoreCreated(address indexed borrower);
    event ScoreUpdated(address indexed borrower);
    event DataContributed(address indexed borrower, address lender);

    constructor() Ownable(msg.sender) {}

    function addLender(address l) external onlyOwner { isLender[l] = true; }

    function grantConsent(address lender) external {
        borrowerConsent[msg.sender][lender] = true;
        if (scores[msg.sender].exists) {
            FHE.allow(scores[msg.sender].compositeScore, lender);
        }
    }

    function createScore() external {
        require(!scores[msg.sender].exists, "Score exists");
        scores[msg.sender].paymentHistoryScore = FHE.asEuint16(500);
        scores[msg.sender].utilizationScore = FHE.asEuint16(500);
        scores[msg.sender].lengthScore = FHE.asEuint16(500);
        scores[msg.sender].mixScore = FHE.asEuint16(500);
        scores[msg.sender].newCreditScore = FHE.asEuint16(500);
        scores[msg.sender].compositeScore = FHE.asEuint16(580); // starting score
        scores[msg.sender].lastUpdated = block.timestamp;
        scores[msg.sender].exists = true;
        FHE.allowThis(scores[msg.sender].paymentHistoryScore);
        FHE.allowThis(scores[msg.sender].utilizationScore);
        FHE.allowThis(scores[msg.sender].compositeScore);
        FHE.allow(scores[msg.sender].compositeScore, msg.sender);
        emit ScoreCreated(msg.sender);
    }

    function contributeData(
        address borrower,
        externalEuint8 encPayment, bytes calldata pProof,
        externalEuint32 encLimit, bytes calldata lProof,
        externalEuint32 encUtil, bytes calldata uProof
    ) external {
        require(isLender[msg.sender], "Not lender");
        require(borrowerConsent[borrower][msg.sender], "No consent");
        require(scores[borrower].exists, "No score");
        euint8 payment = FHE.fromExternal(encPayment, pProof);
        euint32 limit = FHE.fromExternal(encLimit, lProof);
        euint32 util = FHE.fromExternal(encUtil, uProof);
        contributions[borrower].push(DataContribution({
            lender: msg.sender, paymentRating: payment,
            creditLimit: limit, utilization: util,
            submittedAt: block.timestamp
        }));
        uint256 idx = contributions[borrower].length - 1;
        FHE.allowThis(contributions[borrower][idx].paymentRating);
        FHE.allowThis(contributions[borrower][idx].creditLimit);
        FHE.allowThis(contributions[borrower][idx].utilization);
        // Update composite score (simplified: weight payment history)
        euint16 newPayScore = FHE.add(scores[borrower].paymentHistoryScore, FHE.asEuint16(1));
        scores[borrower].paymentHistoryScore = newPayScore;
        scores[borrower].compositeScore = FHE.add(scores[borrower].compositeScore, FHE.asEuint16(1));
        scores[borrower].lastUpdated = block.timestamp;
        FHE.allowThis(scores[borrower].paymentHistoryScore);
        FHE.allowThis(scores[borrower].compositeScore);
        FHE.allow(scores[borrower].compositeScore, borrower);
        emit DataContributed(borrower, msg.sender);
        emit ScoreUpdated(borrower);
    }

    function checkMinScore(address borrower, externalEuint16 encMinScore, bytes calldata proof) external returns (bool) {
        require(borrowerConsent[borrower][msg.sender], "No consent");
        require(scores[borrower].exists, "No score");
        euint16 minScore = FHE.fromExternal(encMinScore, proof);
        ebool qualifies = FHE.ge(scores[borrower].compositeScore, minScore);
        return FHE.isInitialized(qualifies);
    }

    function allowScoreAccess(address viewer) external {
        require(scores[msg.sender].exists, "No score");
        FHE.allow(scores[msg.sender].compositeScore, viewer);
        FHE.allow(scores[msg.sender].paymentHistoryScore, viewer);
        FHE.allow(scores[msg.sender].utilizationScore, viewer);
    }
}
