// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ERC20Capped_b1_003 is ZamaEthereumConfig {
    string public name = "Confidential Capped Token";
    string public symbol = "CCAP";
    
    euint32 private totalSupply;
    euint32 private cap;
    mapping(address => euint32) private balances;

    constructor() {
        totalSupply = FHE.asEuint32(0);
        cap = FHE.asEuint32(10000000);
        FHE.allowThis(totalSupply);
        FHE.allowThis(cap);
    }

    function mint(externalEuint32 amountStr, bytes calldata inputProof) public {
        euint32 amount = FHE.fromExternal(amountStr, inputProof);
        euint32 newSupply = FHE.add(totalSupply, amount);
        
        ebool underCap = FHE.le(newSupply, cap);
        euint32 actualMint = FHE.select(underCap, amount, FHE.asEuint32(0));

        totalSupply = FHE.add(totalSupply, actualMint);
        balances[msg.sender] = FHE.add(balances[msg.sender], actualMint);

        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
    }
}