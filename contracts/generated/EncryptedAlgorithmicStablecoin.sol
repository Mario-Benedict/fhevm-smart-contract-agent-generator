// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EncryptedAlgorithmicStablecoin is ZamaEthereumConfig, Ownable {
    euint64 public totalSupply;
    euint64 public targetPrice;
    euint64 public currentPriceOracle; // Masked oracle price

    mapping(address => euint64) public balances;

    constructor() Ownable(msg.sender) {
        totalSupply = FHE.asEuint64(0);
        targetPrice = FHE.asEuint64(100); // Pegged to 1.00 generically
        currentPriceOracle = FHE.asEuint64(100);
        
        FHE.allowThis(totalSupply);
        FHE.allowThis(targetPrice);
        FHE.allowThis(currentPriceOracle);
    }

    function updateOracle(externalEuint64 priceStr, bytes calldata proof) public onlyOwner {
        currentPriceOracle = FHE.fromExternal(priceStr, proof);
        FHE.allowThis(currentPriceOracle);
    }
    
    function mint(externalEuint64 amountStr, bytes calldata proof) public onlyOwner {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        balances[msg.sender] = FHE.add(balances[msg.sender], amount);
        totalSupply = FHE.add(totalSupply, amount);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(totalSupply);
    }

    function rebase() public onlyOwner {
        ebool isAbovePeg = FHE.gt(currentPriceOracle, targetPrice);
        ebool isBelowPeg = FHE.lt(currentPriceOracle, targetPrice);

        // Simple placeholder arbitrary expansion/contraction offsets natively executed:
        euint64 expansionOffset = FHE.div(totalSupply, 100); // 1%
        euint64 contractionOffset = FHE.div(totalSupply, 50); // 2%

        euint64 afterExpansion = FHE.add(totalSupply, expansionOffset);
        euint64 afterContraction = FHE.sub(totalSupply, contractionOffset);
        
        // Select logic cascading the state.
        euint64 newState = FHE.select(isAbovePeg, afterExpansion, totalSupply);
        newState = FHE.select(isBelowPeg, afterContraction, newState);

        totalSupply = newState;
        FHE.allowThis(totalSupply);
    }
}
