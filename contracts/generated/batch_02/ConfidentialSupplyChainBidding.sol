// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract ConfidentialSupplyChainBidding is ZamaEthereumConfig, AccessControl {
    bytes32 public constant PROCUREMENT_ROLE = keccak256("PROCUREMENT_ROLE");

    euint64 public bestPrice;
    euint64 public bestQualityScore;
    euint64 public maxTargetPrice;
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PROCUREMENT_ROLE, msg.sender);
        
        bestPrice = FHE.asEuint64(type(uint64).max);
        bestQualityScore = FHE.asEuint64(0);
        
        FHE.allowThis(bestPrice);
        FHE.allowThis(bestQualityScore);
    }

    function setMaxPrice(externalEuint64 priceStr, bytes calldata proof) public onlyRole(PROCUREMENT_ROLE) {
        maxTargetPrice = FHE.fromExternal(priceStr, proof);
        FHE.allowThis(maxTargetPrice);
    }

    function submitVendorBid(externalEuint64 bidPriceStr, externalEuint64 qualityScoreStr, bytes calldata proofP, bytes calldata proofQ) public {
        euint64 myBid = FHE.fromExternal(bidPriceStr, proofP);
        euint64 myQuality = FHE.fromExternal(qualityScoreStr, proofQ);

        // Valid if myBid <= maxTargetPrice
        ebool validPrice = FHE.le(myBid, maxTargetPrice);
        
        // Better bid logic: price is lower AND quality is at least as good, or price is same and quality is better
        ebool lowerPrice = FHE.lt(myBid, bestPrice);
        ebool eqPrice = FHE.eq(myBid, bestPrice);
        ebool betterQuality = FHE.gt(myQuality, bestQualityScore);
        ebool eqQuality = FHE.eq(myQuality, bestQualityScore);

        ebool isNewBest = FHE.and(validPrice, 
            FHE.or(
                FHE.and(lowerPrice, FHE.or(betterQuality, eqQuality)),
                FHE.and(eqPrice, betterQuality)
            )
        );

        bestPrice = FHE.select(isNewBest, myBid, bestPrice);
        bestQualityScore = FHE.select(isNewBest, myQuality, bestQualityScore);

        FHE.allowThis(bestPrice);
        FHE.allowThis(bestQualityScore);
    }
}
