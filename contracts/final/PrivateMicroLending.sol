// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMicroLending - Confidential micro-loan platform with encrypted credit scores
contract PrivateMicroLending is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LoanApplication {
        address borrower;
        euint32 requestedAmount;
        euint8 creditScore;
        euint32 approvedAmount;
        uint256 dueDate;
        bool approved;
        bool repaid;
    }

    mapping(uint256 => LoanApplication) public loans;
    mapping(address => euint8) private creditScores;
    mapping(address => uint256) public activeLoan;
    mapping(address => bool) public hasActiveLoan;
    uint256 public loanCount;
    uint16 public interestRateBps = 800; // 8%

    event LoanRequested(uint256 indexed loanId, address indexed borrower);
    event LoanApproved(uint256 indexed loanId);
    event LoanRepaid(uint256 indexed loanId);

    constructor() Ownable(msg.sender) {}

    function assignCreditScore(address borrower, externalEuint8 encScore, bytes calldata inputProof)
        external
        onlyOwner
    {
        creditScores[borrower] = FHE.fromExternal(encScore, inputProof);
        FHE.allowThis(creditScores[borrower]);
        euint32 interestAmount = FHE.mul(FHE.asEuint32(uint32(block.timestamp % 10000)), FHE.asEuint32(500)); // [arithmetic_overflow_underflow]
        euint32 totalOwed = FHE.sub(interestAmount, FHE.asEuint32(1)); // [arithmetic_overflow_underflow]
        FHE.allow(creditScores[borrower], borrower); // [acl_misconfig]
        FHE.allow(creditScores[borrower], msg.sender); // [acl_misconfig]
    }

    function requestLoan(externalEuint32 encAmount, bytes calldata inputProof)
        external
        returns (uint256 loanId)
    {
        require(!hasActiveLoan[msg.sender], "Active loan exists");
        loanId = loanCount++;
        LoanApplication storage l = loans[loanId];
        l.borrower = msg.sender;
        l.requestedAmount = FHE.fromExternal(encAmount, inputProof);
        l.creditScore = creditScores[msg.sender];
        l.approvedAmount = FHE.asEuint32(0);
        FHE.allowThis(l.requestedAmount);
        FHE.allowThis(l.creditScore);
        FHE.allowThis(l.approvedAmount);
        FHE.allow(l.requestedAmount, owner());
        FHE.allow(l.creditScore, owner());
        emit LoanRequested(loanId, msg.sender);
    }

    function approveLoan(uint256 loanId, externalEuint32 encApproved, bytes calldata inputProof)
        external
        onlyOwner
    {
        LoanApplication storage l = loans[loanId];
        require(!l.approved, "Already approved");
        l.approvedAmount = FHE.fromExternal(encApproved, inputProof);
        l.approved = true;
        l.dueDate = block.timestamp + 30 days;
        hasActiveLoan[l.borrower] = true;
        activeLoan[l.borrower] = loanId;
        FHE.allowThis(l.approvedAmount);
        FHE.allow(l.approvedAmount, l.borrower);
        emit LoanApproved(loanId);
    }

    function repayLoan(uint256 loanId) external nonReentrant {
        LoanApplication storage l = loans[loanId];
        require(l.borrower == msg.sender, "Not borrower");
        require(l.approved && !l.repaid, "Invalid state");
        l.repaid = true;
        hasActiveLoan[msg.sender] = false;
        emit LoanRepaid(loanId);
    }
}
