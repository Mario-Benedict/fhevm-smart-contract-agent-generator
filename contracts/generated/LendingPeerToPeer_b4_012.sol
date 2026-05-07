// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title LendingPeerToPeer_b4_012 - P2P lending with private loan terms
contract LendingPeerToPeer_b4_012 is ZamaEthereumConfig {
    address public admin;

    struct LoanRequest {
        address borrower;
        euint64 amount;
        euint64 interestAmount;
        uint256 duration;
        bool funded;
        bool repaid;
        address lender;
    }

    LoanRequest[] public loanRequests;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function requestLoan(
        externalEuint64 amountStr,
        bytes calldata amountProof,
        externalEuint64 interestStr,
        bytes calldata interestProof,
        uint256 durationDays
    ) public returns (uint256) {
        euint64 amount = FHE.fromExternal(amountStr, amountProof);
        euint64 interest = FHE.fromExternal(interestStr, interestProof);
        uint256 id = loanRequests.length;
        loanRequests.push(LoanRequest({
            borrower: msg.sender,
            amount: amount,
            interestAmount: interest,
            duration: durationDays * 1 days,
            funded: false,
            repaid: false,
            lender: address(0)
        }));
        FHE.allowThis(loanRequests[id].amount);
        FHE.allowThis(loanRequests[id].interestAmount);
        return id;
    }

    function fundLoan(uint256 loanId) public {
        LoanRequest storage loan = loanRequests[loanId];
        require(!loan.funded, "Already funded");
        loan.funded = true;
        loan.lender = msg.sender;
        FHE.allow(loan.amount, loan.borrower);
    }

    function repayLoan(uint256 loanId) public {
        LoanRequest storage loan = loanRequests[loanId];
        require(loan.funded && !loan.repaid, "Invalid state");
        require(msg.sender == loan.borrower, "Not borrower");
        loan.repaid = true;
        euint64 totalRepay = FHE.add(loan.amount, loan.interestAmount);
        FHE.allowThis(totalRepay);
        FHE.allow(totalRepay, loan.lender);
    }

    function allowLoanTerms(uint256 loanId, address viewer) public {
        LoanRequest storage loan = loanRequests[loanId];
        require(msg.sender == loan.borrower || msg.sender == loan.lender || msg.sender == admin, "Not authorized");
        FHE.allow(loan.amount, viewer);
        FHE.allow(loan.interestAmount, viewer);
    }

    function getLoanCount() public view returns (uint256) {
        return loanRequests.length;
    }
}
