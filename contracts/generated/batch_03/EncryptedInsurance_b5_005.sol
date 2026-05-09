// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedInsurance_b5_005 is ZamaEthereumConfig {
    address public oracle;
    
    struct Policy {
        euint32 coverageThreshold; // hidden threshold that triggers payout
        euint64 coverageAmount; // hidden payout amount
        ebool isActive;
    }
    
    mapping(address => Policy) private policies;
    mapping(address => euint64) private pendingClaims;

    constructor() {
        oracle = msg.sender;
    }

    function buyPolicy(
        externalEuint32 thresholdStr, 
        externalEuint64 amountStr, 
        bytes calldata proofThresh, 
        bytes calldata proofAmnt
    ) public {
        euint32 thresh = FHE.fromExternal(thresholdStr, proofThresh);
        euint64 amnt = FHE.fromExternal(amountStr, proofAmnt);
        
        policies[msg.sender] = Policy({
            coverageThreshold: thresh,
            coverageAmount: amnt,
            isActive: FHE.asEbool(true)
        });
        FHE.allowThis(policies[msg.sender].coverageThreshold);
        FHE.allowThis(policies[msg.sender].coverageAmount);
        FHE.allowThis(policies[msg.sender].isActive);
    }

    function triggerEvent(address policyHolder, externalEuint32 eventMagnitudeStr, bytes calldata proof) public {
        require(msg.sender == oracle, "Only oracle");
        euint32 magnitude = FHE.fromExternal(eventMagnitudeStr, proof);
        
        Policy storage p = policies[policyHolder];
        
        // If eventMagnitude >= coverageThreshold AND isActive
        ebool conditionMet = FHE.ge(magnitude, p.coverageThreshold);
        ebool triggers = FHE.and(conditionMet, p.isActive);
        
        euint64 payout = FHE.select(triggers, p.coverageAmount, FHE.asEuint64(0));
        pendingClaims[policyHolder] = FHE.add(pendingClaims[policyHolder], payout);
        
        // Deactivate policy if triggered
        p.isActive = FHE.select(triggers, FHE.asEbool(false), p.isActive);

        FHE.allowThis(pendingClaims[policyHolder]);
        FHE.allowThis(p.isActive);
    }
}
