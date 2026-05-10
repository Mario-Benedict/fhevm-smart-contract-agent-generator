// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract BlindKPIBonus_b8_002 is ZamaEthereumConfig {
    address public manager;
    
    struct EmployeeParams {
        euint32 currentKPI;
        euint32 targetKPI;
        euint64 potentialBonus;
        ebool bonusClaimed;
    }

    mapping(address => EmployeeParams) private kpis;
    mapping(address => euint64) private bankBalances;
    euint64 private corporatePool;

    constructor() {
        manager = msg.sender;
        corporatePool = FHE.asEuint64(0);
        FHE.allowThis(corporatePool);
    }

    function fundPool(externalEuint64 amountStr, bytes calldata proof) public {
        require(msg.sender == manager, "Only manager");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        corporatePool = FHE.add(corporatePool, amount);
        FHE.allowThis(corporatePool);
    }

    function setEmployeeTarget(
        address employee, 
        externalEuint32 targetKPIStr, 
        externalEuint64 potentialBonusStr, 
        bytes calldata tProof, 
        bytes calldata bProof
    ) public {
        require(msg.sender == manager, "Only manager");
        
        kpis[employee] = EmployeeParams({
            currentKPI: FHE.asEuint32(0),
            targetKPI: FHE.fromExternal(targetKPIStr, tProof),
            potentialBonus: FHE.fromExternal(potentialBonusStr, bProof),
            bonusClaimed: FHE.asEbool(false)
        });

        FHE.allowThis(kpis[employee].currentKPI);
        FHE.allowThis(kpis[employee].targetKPI);
        FHE.allowThis(kpis[employee].potentialBonus);
        FHE.allowThis(kpis[employee].bonusClaimed);
    }

    function logKPIProgress(address employee, externalEuint32 pointsStr, bytes calldata proof) public {
        require(msg.sender == manager, "Only manager updates KPI");
        euint32 points = FHE.fromExternal(pointsStr, proof);
        kpis[employee].currentKPI = FHE.add(kpis[employee].currentKPI, points);
        FHE.allowThis(kpis[employee].currentKPI);
    }

    function claimBonus() public {
        EmployeeParams storage ep = kpis[msg.sender];
        
        ebool reachedTarget = FHE.ge(ep.currentKPI, ep.targetKPI);
        ebool notClaimed = FHE.not(ep.bonusClaimed);
        
        ebool canClaim = FHE.and(reachedTarget, notClaimed);
        
        ebool poolHasFunds = FHE.ge(corporatePool, ep.potentialBonus);
        ebool finalExecution = FHE.and(canClaim, poolHasFunds);

        euint64 payout = FHE.select(finalExecution, ep.potentialBonus, FHE.asEuint64(0));

        bankBalances[msg.sender] = FHE.add(bankBalances[msg.sender], payout);
        ebool _safeSub13 = FHE.ge(corporatePool, payout);
        corporatePool = FHE.select(_safeSub13, FHE.sub(corporatePool, payout), FHE.asEuint64(0));
        
        ep.bonusClaimed = FHE.select(finalExecution, FHE.asEbool(true), ep.bonusClaimed);

        FHE.allowThis(bankBalances[msg.sender]);
        FHE.allowThis(corporatePool);
        FHE.allowThis(ep.bonusClaimed);
    }
}
