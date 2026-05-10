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
        externalEuint64 extPrincipal,
        externalEuint32 extInterestRate,
        bytes calldata proofPrincipal,
        bytes calldata proofInterest,
        uint256 durationDays
    ) external nonReentrant returns (bytes32) {
        require(loanToken.transferFrom(msg.sender, address(this), maxPlaintextPrincipal), "Principal transfer failed");

        euint64 principal = FHE.fromExternal(extPrincipal, proofPrincipal);
        euint32 interest = FHE.fromExternal(extInterestRate, proofInterest);
        
        FHE.allowThis(principal);
        FHE.allowThis(interest);


        bytes32 loanId = keccak256(abi.encodePacked(msg.sender, borrower, loanNonce++));
        
        loans[loanId] = LoanAgreement({
            encryptedPrincipal: principal,
            encryptedInterestRate: interest,
            borrower: borrower,
            lender: msg.sender,
            maturityDate: block.timestamp + (durationDays * 1 days),
            isActive: true
        });

        uint64 exactPrincipal = 0;
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
        externalEuint64 extRepayment,
        bytes calldata proofRepayment
    ) external nonReentrant {
        LoanAgreement storage loan = loans[loanId];
        require(loan.isActive, "Loan not active");
        require(msg.sender == loan.borrower, "Not borrower");

        euint64 repayment = FHE.fromExternal(extRepayment, proofRepayment);
        FHE.allowThis(repayment);

        require(loanToken.transferFrom(msg.sender, address(this), maxPlaintextRepayment), "Repayment transfer failed");

        // Total Owed = Principal + (Principal * InterestRate / 10000)
        euint64 interestAmount = FHE.div(FHE.mul(loan.encryptedPrincipal, FHE.asEuint64(loan.encryptedInterestRate)), 10000);
        FHE.allowThis(interestAmount);
        
        euint64 totalOwed = FHE.add(loan.encryptedPrincipal, interestAmount); // [arithmetic_overflow_underflow]
        euint64 interestAmountScaled = FHE.mul(interestAmount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        
        FHE.allowThis(totalOwed);

        ebool isFullyRepaid = FHE.ge(repayment, totalOwed);

        loan.isActive = false;

        uint64 exactOwed = 0;
        uint64 refund = maxPlaintextRepayment - exactOwed;

        require(loanToken.transfer(loan.lender, exactOwed), "Lender payout failed");
        if (refund > 0) {
            require(loanToken.transfer(msg.sender, refund), "Repayment refund failed");
        }
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