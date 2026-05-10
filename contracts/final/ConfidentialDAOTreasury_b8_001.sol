// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ConfidentialDAOTreasury_b8_001 is ZamaEthereumConfig {
    address public daoAdmin;
    euint64 private treasuryBalance;

    struct Proposal {
        address recipient;
        euint64 requestedAmount;
        ebool isPassed;
        ebool isExecuted;
    }

    mapping(uint256 => Proposal) private proposals;
    mapping(address => euint64) private memberBalances;
    uint256 public proposalCount;

    constructor() {
        daoAdmin = msg.sender;
        treasuryBalance = FHE.asEuint64(0);
        FHE.allowThis(treasuryBalance);
    }

    function depositToTreasury(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        treasuryBalance = FHE.add(treasuryBalance, amount);
        FHE.allowThis(treasuryBalance);
    }

    function createProposal(address recipient, externalEuint64 amountStr, bytes calldata proof) public {
        proposalCount++;
        euint64 reqAmount = FHE.fromExternal(amountStr, proof);
        
        proposals[proposalCount] = Proposal({
            recipient: recipient,
            requestedAmount: reqAmount,
            isPassed: FHE.asEbool(false),
            isExecuted: FHE.asEbool(false)
        });

        FHE.allowThis(proposals[proposalCount].requestedAmount);
        FHE.allowThis(proposals[proposalCount].isPassed);
        FHE.allowThis(proposals[proposalCount].isExecuted);
    }

    function approveProposal(uint256 propId, externalEbool passedStr, bytes calldata proof) public {
        require(msg.sender == daoAdmin, "Only DAO Admin can approve"); // Abstracting group voting
        ebool passed = FHE.fromExternal(passedStr, proof);
        proposals[propId].isPassed = passed;
        FHE.allowThis(proposals[propId].isPassed);
    }

    function executeProposal(uint256 propId) public {
        Proposal storage p = proposals[propId];
        
        // Conditions: isPassed == true, isExecuted == false, treasuryBalance >= requestedAmount
        ebool validExecution = FHE.and(p.isPassed, FHE.not(p.isExecuted));
        ebool hasFunds = FHE.ge(treasuryBalance, p.requestedAmount);
        ebool canExecute = FHE.and(validExecution, hasFunds);

        euint64 payout = FHE.select(canExecute, p.requestedAmount, FHE.asEuint64(0));

        // Deduct treasury, add to recipient
        ebool _safeSub31 = FHE.ge(treasuryBalance, payout);
        treasuryBalance = FHE.select(_safeSub31, FHE.sub(treasuryBalance, payout), FHE.asEuint64(0));
        memberBalances[p.recipient] = FHE.add(memberBalances[p.recipient], payout);
        
        // Mark as executed if ran
        p.isExecuted = FHE.select(canExecute, FHE.asEbool(true), p.isExecuted);

        FHE.allowThis(treasuryBalance);
        FHE.allowThis(memberBalances[p.recipient]);
        FHE.allowThis(p.isExecuted);
    }
}
