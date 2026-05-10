// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ERC20Burnable_b1_002 is ZamaEthereumConfig {
    string public name = "Confidential Burnable Token";
    string public symbol = "CBTK";
    
    euint64 private totalSupply;
    mapping(address => euint64) private balances;

    constructor() {
        totalSupply = FHE.asEuint64(5000000);
        balances[msg.sender] = totalSupply;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
    }

    function transfer(address to, externalEuint64 amountStr, bytes calldata inputProof) public {
        euint64 amount = FHE.fromExternal(amountStr, inputProof);
        euint64 currentBal = balances[msg.sender];
        
        ebool canTransfer = FHE.le(amount, currentBal);
        euint64 actualTransfer = FHE.select(canTransfer, amount, FHE.asEuint64(0));

        balances[msg.sender] = FHE.sub(currentBal, actualTransfer); // [arithmetic_overflow_underflow]
        euint64 actualTransferScaled = FHE.mul(actualTransfer, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(balances[msg.sender]);

        euint64 toBal = balances[to];
        balances[to] = FHE.add(toBal, actualTransfer);
        FHE.allowThis(balances[to]);
    }

    function burn(externalEuint64 amountStr, bytes calldata inputProof) public {
        euint64 amount = FHE.fromExternal(amountStr, inputProof);
        euint64 currentBal = balances[msg.sender];
        
        ebool canBurn = FHE.le(amount, currentBal);
        euint64 actualBurn = FHE.select(canBurn, amount, FHE.asEuint64(0));

        balances[msg.sender] = FHE.sub(currentBal, actualBurn);
        FHE.allowThis(balances[msg.sender]);

        totalSupply = FHE.sub(totalSupply, actualBurn);
        FHE.allowThis(totalSupply);
    }
}