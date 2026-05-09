// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCreditScoring - On-chain credit scoring with encrypted repayment history
contract PrivateCreditScoring is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct CreditProfile {
        euint16 score;               // encrypted 300-850 range
        euint32 totalBorrowed;
        euint32 totalRepaid;
        euint8 missedPayments;
        euint8 onTimePayments;
        uint256 accountAge;          // days
        bool exists;
    }

    mapping(address => CreditProfile) private profiles;
    mapping(address => bool) public isCreditBureau;
    mapping(address => bool) public isLender;
    euint16 private _minimumLendingScore;

    event ProfileCreated(address indexed borrower);
    event ScoreUpdated(address indexed borrower);
    event LoanApproved(address indexed borrower, address lender);
    event LoanDenied(address indexed borrower);

    constructor(externalEuint16 encMinScore, bytes memory proof) Ownable(msg.sender) {
        _minimumLendingScore = FHE.fromExternal(encMinScore, proof);
        FHE.allowThis(_minimumLendingScore);
        isCreditBureau[msg.sender] = true;
    }

    function addCreditBureau(address b) external onlyOwner { isCreditBureau[b] = true; }
    function addLender(address l) external onlyOwner { isLender[l] = true; }

    function createProfile(address borrower) external {
        require(isCreditBureau[msg.sender], "Not bureau");
        profiles[borrower] = CreditProfile({
            score: FHE.asEuint16(650), // start at 650
            totalBorrowed: FHE.asEuint32(0),
            totalRepaid: FHE.asEuint32(0),
            missedPayments: FHE.asEuint8(0),
            onTimePayments: FHE.asEuint8(0),
            accountAge: 0,
            exists: true
        });
        FHE.allowThis(profiles[borrower].score);
        FHE.allow(profiles[borrower].score, borrower);
        FHE.allowThis(profiles[borrower].totalBorrowed);
        FHE.allowThis(profiles[borrower].totalRepaid);
        FHE.allowThis(profiles[borrower].missedPayments);
        FHE.allowThis(profiles[borrower].onTimePayments);
        emit ProfileCreated(borrower);
    }

    function recordPayment(address borrower, bool onTime, externalEuint32 encAmount, bytes calldata proof) external {
        require(isLender[msg.sender], "Not lender");
        euint32 amount = FHE.fromExternal(encAmount, proof);
        CreditProfile storage p = profiles[borrower];
        if (onTime) {
            p.onTimePayments = FHE.add(p.onTimePayments, FHE.asEuint8(1));
            p.totalRepaid = FHE.add(p.totalRepaid, amount);
            // Boost score by 2 points per on-time payment
            p.score = FHE.add(p.score, FHE.asEuint16(2));
            FHE.allowThis(p.onTimePayments); FHE.allowThis(p.totalRepaid);
        } else {
            p.missedPayments = FHE.add(p.missedPayments, FHE.asEuint8(1));
            // Reduce score by 10 points per missed
            p.score = FHE.sub(p.score, FHE.asEuint16(10));
            FHE.allowThis(p.missedPayments);
        }
        FHE.allowThis(p.score);
        FHE.allow(p.score, borrower);
        emit ScoreUpdated(borrower);
    }

    function checkLoanEligibility(address borrower) external returns (ebool eligible) {
        require(isLender[msg.sender], "Not lender");
        eligible = FHE.ge(profiles[borrower].score, _minimumLendingScore);
        FHE.allow(eligible, msg.sender);
        FHE.allow(eligible, borrower);
        FHE.allowThis(eligible);
        if (FHE.isInitialized(eligible)) {
            emit LoanApproved(borrower, msg.sender);
        } else {
            emit LoanDenied(borrower);
        }
    }

    function allowProfile(address borrower, address viewer) external {
        require(isCreditBureau[msg.sender] || msg.sender == borrower, "Unauthorized");
        FHE.allow(profiles[borrower].score, viewer);
        FHE.allow(profiles[borrower].onTimePayments, viewer);
        FHE.allow(profiles[borrower].missedPayments, viewer);
    }
}
