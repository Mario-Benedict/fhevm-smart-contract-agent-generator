// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StealthP2PLending is ZamaEthereumConfig, ReentrancyGuard {
    IERC20 public immutable loanToken;

    struct LoanAgreement {
        euint64 encryptedPrincipal;
        euint32 encryptedInterestRate; // Basis points
        address borrower;
        address lender;
        uint256 maturityDate;
        bool isActive;
    }

    mapping(bytes32 => LoanAgreement) public loans;
    uint256 private loanNonce;

    constructor(address _loanToken) {
        loanToken = IERC20(_loanToken);
    }

    function initiateStealthLoan(
        address borrower,
        uint64 maxPlaintextPrincipal,
        externalEuint64 memory extPrincipal,
        externalEuint32 memory extInterestRate,
        bytes calldata proofPrincipal,
        bytes calldata proofInterest,
        uint256 durationDays
    ) external nonReentrant returns (bytes32) {
        require(loanToken.transferFrom(msg.sender, address(this), maxPlaintextPrincipal), "Principal transfer failed");

        euint64 principal = FHE.fromExternal(extPrincipal, proofPrincipal);
        euint32 interest = FHE.fromExternal(extInterestRate, proofInterest);
        
        FHE.allowThis(principal);
        FHE.allowThis(interest);

        FHE.req(FHE.le(principal, FHE.asEuint64(maxPlaintextPrincipal)));

        bytes32 loanId = keccak256(abi.encodePacked(msg.sender, borrower, loanNonce++));
        
        loans[loanId] = LoanAgreement({
            encryptedPrincipal: principal,
            encryptedInterestRate: interest,
            borrower: borrower,
            lender: msg.sender,
            maturityDate: block.timestamp + (durationDays * 1 days),
            isActive: true
        });

        uint64 exactPrincipal = FHE.decrypt(principal);
        uint64 refund = maxPlaintextPrincipal - exactPrincipal;

        require(loanToken.transfer(borrower, exactPrincipal), "Loan disbursement failed");
        if (refund > 0) {
            require(loanToken.transfer(msg.sender, refund), "Refund failed");
        }

        return loanId;
    }

    function repayStealthLoan(
        bytes32 loanId,
        uint64 maxPlaintextRepayment,
        externalEuint64 memory extRepayment,
        bytes calldata proofRepayment
    ) external nonReentrant {
        LoanAgreement storage loan = loans[loanId];
        require(loan.isActive, "Loan not active");
        require(msg.sender == loan.borrower, "Not borrower");

        euint64 repayment = FHE.fromExternal(extRepayment, proofRepayment);
        FHE.allowThis(repayment);

        require(loanToken.transferFrom(msg.sender, address(this), maxPlaintextRepayment), "Repayment transfer failed");
        FHE.req(FHE.le(repayment, FHE.asEuint64(maxPlaintextRepayment)));

        // Total Owed = Principal + (Principal * InterestRate / 10000)
        euint64 interestAmount = FHE.div(FHE.mul(loan.encryptedPrincipal, FHE.asEuint64(loan.encryptedInterestRate)), 10000);
        FHE.allowThis(interestAmount);
        
        euint64 totalOwed = FHE.add(loan.encryptedPrincipal, interestAmount);
        FHE.allowThis(totalOwed);

        ebool isFullyRepaid = FHE.ge(repayment, totalOwed);
        FHE.req(isFullyRepaid);

        loan.isActive = false;

        uint64 exactOwed = FHE.decrypt(totalOwed);
        uint64 refund = maxPlaintextRepayment - exactOwed;

        require(loanToken.transfer(loan.lender, exactOwed), "Lender payout failed");
        if (refund > 0) {
            require(loanToken.transfer(msg.sender, refund), "Repayment refund failed");
        }
    }
}