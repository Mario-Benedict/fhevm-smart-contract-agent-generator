// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract LendingCollateral_b2_005 is ZamaEthereumConfig {
    mapping(address => euint64) private collateral;
    mapping(address => euint64) private debt;

    constructor() {
        collateral[msg.sender] = FHE.asEuint64(0);
        debt[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(collateral[msg.sender]);
        FHE.allowThis(debt[msg.sender]);
    }

    function depositCollateral(externalEuint64 amountStr, bytes calldata inputProof) public {
        euint64 amount = FHE.fromExternal(amountStr, inputProof);
        euint64 currentColl = collateral[msg.sender];
        collateral[msg.sender] = FHE.add(currentColl, amount);
        FHE.allowThis(collateral[msg.sender]);
    }

    function borrow(externalEuint64 amountStr, bytes calldata inputProof) public {
        euint64 borrowAmount = FHE.fromExternal(amountStr, inputProof);
        euint64 currentDebt = debt[msg.sender];
        
        euint64 potentialDebt = FHE.add(currentDebt, borrowAmount);
        
        // Require 200% collateral linearly (collateral >= debt * 2) 
        euint64 requiredCollateral = FHE.mul(potentialDebt, FHE.asEuint64(2));

        ebool canBorrow = FHE.le(requiredCollateral, collateral[msg.sender]);
        euint64 actualBorrow = FHE.select(canBorrow, borrowAmount, FHE.asEuint64(0));

        debt[msg.sender] = FHE.add(currentDebt, actualBorrow);
        FHE.allowThis(debt[msg.sender]);
    }
}
