// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BlindPeerReviewSystem is ZamaEthereumConfig, Ownable {
    struct Review {
        address reviewer;
        euint64 technicalScore; // 1 to 10
        euint64 communicationScore; // 1 to 10
        ebool submitted;
    }

    mapping(uint256 => mapping(address => Review)) private _reviews;
    mapping(uint256 => address[]) private _reviewersForCycle;
    
    uint256 public cycleCount;

    event PeerReviewCycleStarted(uint256 indexed cycleId);
    event ReviewSubmitted(uint256 indexed cycleId, address indexed reviewer);

    constructor() Ownable(msg.sender) {
        cycleCount = 0;
    }

    function startReviewCycle(address[] calldata selectedReviewers) external onlyOwner returns (uint256 id) {
        id = cycleCount++;
        for (uint256 i = 0; i < selectedReviewers.length; i++) {
            _reviewersForCycle[id].push(selectedReviewers[i]);
            _reviews[id][selectedReviewers[i]].submitted = FHE.asEbool(false);
            FHE.allowThis(_reviews[id][selectedReviewers[i]].submitted);
        }
        emit PeerReviewCycleStarted(id);
    }

    function submitReview(uint256 cycleId, 
                          externalEuint64 techStr, bytes calldata proofTech,
                          externalEuint64 commsStr, bytes calldata proofComm) external {
        
        Review storage r = _reviews[cycleId][msg.sender];
        
        euint64 ts = FHE.fromExternal(techStr, proofTech);
        euint64 cs = FHE.fromExternal(commsStr, proofComm);
        
        ebool isNotSubmitted = FHE.not(r.submitted);
        
        r.technicalScore = FHE.select(isNotSubmitted, ts, r.technicalScore);
        r.communicationScore = FHE.select(isNotSubmitted, cs, r.communicationScore);
        r.submitted = FHE.select(isNotSubmitted, FHE.asEbool(true), r.submitted);
        
        FHE.allowThis(r.technicalScore);
        FHE.allowThis(r.communicationScore);
        FHE.allowThis(r.submitted);
        
        emit ReviewSubmitted(cycleId, msg.sender);
    }

    function aggregateCycleScores(uint256 cycleId) external onlyOwner returns (euint64, euint64) {
        euint64 totalTech = FHE.asEuint64(0);
        euint64 totalComms = FHE.asEuint64(0);
        
        address[] memory reviewers = _reviewersForCycle[cycleId];
        
        for (uint256 i = 0; i < reviewers.length; i++) {
            Review storage r = _reviews[cycleId][reviewers[i]];
            euint64 techCont = FHE.select(r.submitted, r.technicalScore, FHE.asEuint64(0));
            euint64 commsCont = FHE.select(r.submitted, r.communicationScore, FHE.asEuint64(0));
            
            totalTech = FHE.add(totalTech, techCont);
            totalComms = FHE.add(totalComms, commsCont);
        }
        
        // Cannot divide natively by dynamic number of reviewers unless plaintext. 
        // We will divide by the static length of array.
        uint64 count = uint64(reviewers.length);
        
        // For actual average we require division by plaintext literal, since division by encrypted divisor throws error
        // But since `reviewers.length` is plaintext, we can do FHE.div(a, uint)
        euint64 avgTech;
        euint64 avgComm;
        
        if (count > 0) {
            avgTech = FHE.div(totalTech, count);
            avgComm = FHE.div(totalComms, count);
        } else {
            avgTech = FHE.asEuint64(0);
            avgComm = FHE.asEuint64(0);
        }

        return (avgTech, avgComm); // Can only be decrypted by DApp
    }
}