// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ERC20Reward_b1_005 is ZamaEthereumConfig {
    string public name = "Confidential Reward Token";
    string public symbol = "CRWD";
    
    euint32 private totalSupply;
    mapping(address => euint32) private balances;
    address public owner;

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint32(100000);
        balances[msg.sender] = totalSupply;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
    }

    function transfer(address to, externalEuint32 amountStr, bytes calldata inputProof) public {
        euint32 amount = FHE.fromExternal(amountStr, inputProof);
        euint32 currentBal = balances[msg.sender];
        
        ebool canTransfer = FHE.le(amount, currentBal);
        euint32 actualTransfer = FHE.select(canTransfer, amount, FHE.asEuint32(0));

        balances[msg.sender] = FHE.sub(currentBal, actualTransfer); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(balances[msg.sender]);

        balances[to] = FHE.add(balances[to], actualTransfer);
        FHE.allowThis(balances[to]);
    }

    function distributeReward(address[] memory users, externalEuint32 amountStr, bytes calldata inputProof) public {
        require(msg.sender == owner, "Only owner");
        euint32 amountPerUser = FHE.fromExternal(amountStr, inputProof);
        
        for (uint i = 0; i < users.length; i++) {
            balances[users[i]] = FHE.add(balances[users[i]], amountPerUser);
            FHE.allowThis(balances[users[i]]);
        }
    }
}