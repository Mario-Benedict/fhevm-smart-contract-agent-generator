// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ConfidentialBounty_b7_001 is ZamaEthereumConfig {
    address public sponsor;
    euint64 private bountyPool;

    struct Submission {
        euint32 assertedSeverity;
        ebool isProcessed;
    }

    mapping(address => Submission) private submissions;
    mapping(address => euint64) private hunterBalances;

    constructor() {
        sponsor = msg.sender;
        bountyPool = FHE.asEuint64(0);
        FHE.allowThis(bountyPool);
    }

    function fundBounty(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        bountyPool = FHE.add(bountyPool, amount);
        FHE.allowThis(bountyPool);
    }

    function submitBug(externalEuint32 severityStr, bytes calldata proof) public {
        euint32 severity = FHE.fromExternal(severityStr, proof);
        submissions[msg.sender] = Submission({
            assertedSeverity: severity,
            isProcessed: FHE.asEbool(false)
        });
        FHE.allowThis(submissions[msg.sender].assertedSeverity);
        FHE.allowThis(submissions[msg.sender].isProcessed);
    }

    // Sponsor validates and awards blindly. Severity mapping: 1=Low, 2=Med, 3=High.
    function processSubmission(
        address hunter, 
        externalEuint32 actualSeverityStr, 
        bytes calldata proofSev,
        externalEuint64 rewardAmountStr,
        bytes calldata proofRew
    ) public {
        require(msg.sender == sponsor, "Only sponsor");
        
        euint32 actualSeverity = FHE.fromExternal(actualSeverityStr, proofSev);
        euint64 rewardAmount = FHE.fromExternal(rewardAmountStr, proofRew);

        Submission storage sub = submissions[hunter];

        // Valid if actualSeverity matches or exceeds the asserted severity
        ebool isValid = FHE.ge(actualSeverity, sub.assertedSeverity);
        ebool canExecute = FHE.and(isValid, FHE.not(sub.isProcessed));

        // Payout evaluation
        euint64 payout = FHE.select(canExecute, rewardAmount, FHE.asEuint64(0));

        // Check pool liquidity
        ebool hasFunds = FHE.le(payout, bountyPool);
        euint64 finalPayout = FHE.select(hasFunds, payout, FHE.asEuint64(0));

        ebool _safeSub19 = FHE.ge(bountyPool, finalPayout);
        bountyPool = FHE.select(_safeSub19, FHE.sub(bountyPool, finalPayout), FHE.asEuint64(0));
        
        euint64 previousBal = hunterBalances[hunter];
        hunterBalances[hunter] = FHE.add(previousBal, finalPayout);
        
        sub.isProcessed = FHE.select(canExecute, FHE.asEbool(true), sub.isProcessed);

        FHE.allowThis(bountyPool);
        FHE.allowThis(hunterBalances[hunter]);
        FHE.allowThis(sub.isProcessed);
    }
}
