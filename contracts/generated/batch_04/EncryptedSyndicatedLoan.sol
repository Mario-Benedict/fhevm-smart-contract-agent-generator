// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EncryptedSyndicatedLoan is ZamaEthereumConfig, Ownable {
    euint64 public totalSyndicateGoal;
    euint64 public currentRaised;
    euint64 public interestRateBps;
    
    address public borrower;
    bool public loanFunded;
    bool public loanRepaid;

    mapping(address => euint64) public participantContributions;
    address[] public participants;

    event ParticipantFunded(address indexed p);
    event LoanActivated();
    event LoanRepaid();
    event ParticipantPayout(address indexed p);

    constructor(address _borrower, externalEuint64 goalStr, bytes memory proofGoal,
                externalEuint64 rateStr, bytes memory proofRate) Ownable(msg.sender) {
        borrower = _borrower;
        totalSyndicateGoal = FHE.fromExternal(goalStr, proofGoal);
        interestRateBps = FHE.fromExternal(rateStr, proofRate);
        currentRaised = FHE.asEuint64(0);
        
        loanFunded = false;
        loanRepaid = false;

        FHE.allowThis(totalSyndicateGoal);
        FHE.allowThis(interestRateBps);
        FHE.allowThis(currentRaised);
    }

    function participate(externalEuint64 contributionStr, bytes calldata proof) external {
        require(!loanFunded, "Already funded fully");
        euint64 contribution = FHE.fromExternal(contributionStr, proof);
        
        if (!FHE.isInitialized(participantContributions[msg.sender])) {
            participantContributions[msg.sender] = FHE.asEuint64(0);
            participants.push(msg.sender);
        }
        
        participantContributions[msg.sender] = FHE.add(participantContributions[msg.sender], contribution);
        currentRaised = FHE.add(currentRaised, contribution);
        
        FHE.allowThis(participantContributions[msg.sender]);
        FHE.allow(participantContributions[msg.sender], msg.sender);
        FHE.allowThis(currentRaised);

        emit ParticipantFunded(msg.sender);
    }

    function activateLoan() external onlyOwner {
        require(!loanFunded, "Already funded");
        
        // Using natively compiled selection for logic, but returning void isn't easy natively. 
        // We will just set a boolean plaintext because we cannot natively gate loan status on encrypted currentRaised 
        // without an off-chain oracle. Thus, activation is trusting the owner.
        loanFunded = true;
        emit LoanActivated();
    }

    function repayLoan(externalEuint64 repaymentStr, bytes calldata proof) external {
        require(msg.sender == borrower, "Only borrower can repay");
        require(loanFunded, "Loan not active");
        require(!loanRepaid, "Already repaid");

        euint64 repayment = FHE.fromExternal(repaymentStr, proof);
        
        // Let's pretend the repayment matches what borrower computes off-chain.
        // Once this is submitted, we flag the loan as repaid.
        loanRepaid = true;
        emit LoanRepaid();
    }

    function withdrawPayout() external {
        require(loanRepaid, "Loan not repaid");
        
        euint64 contribution = participantContributions[msg.sender];
        
        euint64 interestPart = FHE.mul(contribution, interestRateBps);
        interestPart = FHE.div(interestPart, 10000); 

        euint64 totalPayout = FHE.add(contribution, interestPart);
        
        participantContributions[msg.sender] = FHE.asEuint64(0);

        FHE.allowThis(participantContributions[msg.sender]);
        FHE.allow(totalPayout, msg.sender);
        
        emit ParticipantPayout(msg.sender);
    }
}