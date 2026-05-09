// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract AnonymousPeerReview_b12_003 is ZamaEthereumConfig {
    address public hrAdmin;
    euint64 public maxScore;

    mapping(address => euint64) private totalScores;
    mapping(address => euint64) private reviewCounts;

    constructor() {
        hrAdmin = msg.sender;
        maxScore = FHE.asEuint64(100);
        FHE.allowThis(maxScore);
    }

    function submitReview(address colleague, externalEuint64 scoreStr, bytes calldata proof) public {
        euint64 score = FHE.fromExternal(scoreStr, proof);
        
        // Bound score blindly. If score > 100, clamp it to 100
        ebool isOver = FHE.gt(score, maxScore);
        euint64 finalScore = FHE.select(isOver, maxScore, score);

        totalScores[colleague] = FHE.add(totalScores[colleague], finalScore);
        reviewCounts[colleague] = FHE.add(reviewCounts[colleague], FHE.asEuint64(1));

        FHE.allowThis(totalScores[colleague]);
        FHE.allowThis(reviewCounts[colleague]);
    }

    // Averages must be resolved off-chain through unsealing, but we store the aggregates blindly.
    function checkPromotionEligibility(address colleague) public returns (ebool) {
        // Needs total > 300 to be automatically flagged for promotion consideration blindly
        ebool eligible = FHE.ge(totalScores[colleague], FHE.asEuint64(300));
        return eligible;
    }
}
