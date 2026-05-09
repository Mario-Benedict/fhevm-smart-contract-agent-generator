// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ConfidentialEmployeeBonusSystem is ZamaEthereumConfig, Ownable {
    struct BonusTier {
        euint64 lowThreshold;
        euint64 highThreshold;
        euint64 multiplier;
    }

    mapping(address => euint64) public baseSalaries;
    mapping(address => euint64) public performanceScores;
    mapping(address => euint64) public rewardedBonuses;
    
    mapping(uint8 => BonusTier) private tiers;
    uint8 public numTiers;

    event EmployeeAdded(address indexed emp);
    event PerformanceScored(address indexed emp);
    event BonusDisbursed(address indexed emp);

    constructor() Ownable(msg.sender) {
        numTiers = 0;
    }

    function addTier(externalEuint64 lowStr, bytes calldata proofLow,
                     externalEuint64 highStr, bytes calldata proofHigh,
                     externalEuint64 multStr, bytes calldata proofMult) external onlyOwner {
        tiers[numTiers] = BonusTier({
            lowThreshold: FHE.fromExternal(lowStr, proofLow),
            highThreshold: FHE.fromExternal(highStr, proofHigh),
            multiplier: FHE.fromExternal(multStr, proofMult)
        });
        FHE.allowThis(tiers[numTiers].lowThreshold);
        FHE.allowThis(tiers[numTiers].highThreshold);
        FHE.allowThis(tiers[numTiers].multiplier);
        numTiers++;
    }

    function setEmployeeData(address emp, externalEuint64 baseStr, bytes calldata proof) external onlyOwner {
        baseSalaries[emp] = FHE.fromExternal(baseStr, proof);
        performanceScores[emp] = FHE.asEuint64(0);
        rewardedBonuses[emp] = FHE.asEuint64(0);
        FHE.allowThis(baseSalaries[emp]);
        FHE.allowThis(performanceScores[emp]);
        FHE.allowThis(rewardedBonuses[emp]);
        FHE.allow(baseSalaries[emp], emp);
        emit EmployeeAdded(emp);
    }

    function submitPerformanceScore(address emp, externalEuint64 scoreStr, bytes calldata proof) external onlyOwner {
        performanceScores[emp] = FHE.fromExternal(scoreStr, proof);
        FHE.allowThis(performanceScores[emp]);
        emit PerformanceScored(emp);
    }

    function calculateAndDisburseBonus(address emp) external {
        require(msg.sender == emp || msg.sender == owner(), "Unauthorized");
        euint64 score = performanceScores[emp];
        euint64 base = baseSalaries[emp];
        
        euint64 totalBonus = FHE.asEuint64(0);

        for (uint8 i = 0; i < numTiers; i++) {
            BonusTier storage t = tiers[i];
            ebool isAboveLow = FHE.ge(score, t.lowThreshold);
            ebool isBelowHigh = FHE.le(score, t.highThreshold);
            ebool inTier = FHE.and(isAboveLow, isBelowHigh);

            euint64 potentialBonus = FHE.mul(base, t.multiplier);
            potentialBonus = FHE.div(potentialBonus, 100); 

            euint64 actualBonus = FHE.select(inTier, potentialBonus, FHE.asEuint64(0));
            totalBonus = FHE.add(totalBonus, actualBonus);
        }

        rewardedBonuses[emp] = FHE.add(rewardedBonuses[emp], totalBonus);
        performanceScores[emp] = FHE.asEuint64(0); 

        FHE.allowThis(rewardedBonuses[emp]);
        FHE.allow(rewardedBonuses[emp], emp);
        FHE.allowThis(performanceScores[emp]);

        emit BonusDisbursed(emp);
    }
}