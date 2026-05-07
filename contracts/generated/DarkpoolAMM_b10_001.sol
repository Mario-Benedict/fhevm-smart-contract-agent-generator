// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract DarkpoolAMM_b10_001 is ZamaEthereumConfig {
    euint64 private reserveA;
    euint64 private reserveB;
    
    mapping(address => euint64) private balanceA;
    mapping(address => euint64) private balanceB;

    constructor() {
        reserveA = FHE.asEuint64(0);
        reserveB = FHE.asEuint64(0);
        FHE.allowThis(reserveA);
        FHE.allowThis(reserveB);
    }

    function addLiquidity(externalEuint64 amountAStr, externalEuint64 amountBStr, bytes calldata proofA, bytes calldata proofB) public {
        euint64 amountA = FHE.fromExternal(amountAStr, proofA);
        euint64 amountB = FHE.fromExternal(amountBStr, proofB);
        
        reserveA = FHE.add(reserveA, amountA);
        reserveB = FHE.add(reserveB, amountB);
        
        FHE.allowThis(reserveA);
        FHE.allowThis(reserveB);
    }

    function depositA(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        balanceA[msg.sender] = FHE.add(balanceA[msg.sender], amount);
        FHE.allowThis(balanceA[msg.sender]);
    }

    function swapAforB(externalEuint64 amountInAStr, externalEuint64 minOutBStr, bytes calldata proofIn, bytes calldata proofMin) public {
        euint64 amountInA = FHE.fromExternal(amountInAStr, proofIn);
        euint64 minOutB = FHE.fromExternal(minOutBStr, proofMin);
        
        // Constant product formula approximation: outB = (amountInA * reserveB) / (reserveA + amountInA)
        // Note: FHE.div only supports plaintext divisor. We can't do full AMM division.
        // WORKAROUND: Assume a fixed 1:1 price ratio pool but with sliding hidden fees, or linear bonding curve.
        // Let's implement a simple 1:1 swap with hidden reserves constraint.
        
        ebool canAfford = FHE.ge(balanceA[msg.sender], amountInA);
        ebool poolHasB = FHE.ge(reserveB, amountInA); 
        ebool satisfiesMin = FHE.ge(amountInA, minOutB);
        
        ebool canSwap = FHE.and(FHE.and(canAfford, poolHasB), satisfiesMin);
        
        euint64 actualSwap = FHE.select(canSwap, amountInA, FHE.asEuint64(0));
        
        balanceA[msg.sender] = FHE.sub(balanceA[msg.sender], actualSwap);
        balanceB[msg.sender] = FHE.add(balanceB[msg.sender], actualSwap);
        
        reserveA = FHE.add(reserveA, actualSwap);
        reserveB = FHE.sub(reserveB, actualSwap);
        
        FHE.allowThis(balanceA[msg.sender]);
        FHE.allowThis(balanceB[msg.sender]);
        FHE.allowThis(reserveA);
        FHE.allowThis(reserveB);
    }
}
