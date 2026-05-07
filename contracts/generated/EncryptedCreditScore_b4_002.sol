// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedCreditScore_b4_002 is ZamaEthereumConfig {
    address public trustedOracle;
    mapping(address => euint32) private creditScores;
    mapping(address => uint256) public lastUpdate;

    constructor() {
        trustedOracle = msg.sender;
    }

    // Oracle updates the score confidentially
    function updateScore(address user, externalEuint32 newScoreStr, bytes calldata proof) public {
        require(msg.sender == trustedOracle, "Only oracle can update");
        euint32 score = FHE.fromExternal(newScoreStr, proof);
        creditScores[user] = score;
        lastUpdate[user] = block.timestamp;
        FHE.allowThis(creditScores[user]);
    }

    // User can request loan approval where loan provider provides threshold
    function checkLoanEligibility(address user, externalEuint32 thresholdStr, bytes calldata proof) public returns (ebool) {
        euint32 threshold = FHE.fromExternal(thresholdStr, proof);
        
        // Ensures score exists
        require(lastUpdate[user] != 0, "No credit history");

        // Returns encrypted true if score >= threshold
        ebool isEligible = FHE.ge(creditScores[user], threshold);
        
        // We do NOT decrypt it here to keep eligibility confidential,
        // The calling loan contract or backend can utilize this ebool.
        return isEligible;
    }
    
    // Penalize score if user missed a decentralized payment
    function reportMissedPayment(address user, externalEuint32 penaltyStr, bytes calldata proof) public {
        require(msg.sender == trustedOracle, "Only oracle can penalize");
        euint32 penalty = FHE.fromExternal(penaltyStr, proof);
        
        euint32 currentScore = creditScores[user];
        ebool canDeduct = FHE.ge(currentScore, penalty);
        euint32 actualPenalty = FHE.select(canDeduct, penalty, currentScore); // Prevent underflow
        
        creditScores[user] = FHE.sub(currentScore, actualPenalty);
        FHE.allowThis(creditScores[user]);
    }
}
