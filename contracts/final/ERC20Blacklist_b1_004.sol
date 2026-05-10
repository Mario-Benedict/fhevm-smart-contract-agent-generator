// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ERC20Blacklist_b1_004 is ZamaEthereumConfig {
    string public name = "Confidential Token with Blacklist";
    string public symbol = "CTB";
    
    euint64 private totalSupply;
    mapping(address => euint64) private balances;
    mapping(address => bool) public isBlacklisted;
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint64(2000000);
        balances[msg.sender] = totalSupply;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
    }

    function setBlacklist(address target, bool status) public onlyOwner {
        isBlacklisted[target] = status;
    }

    function transfer(address to, externalEuint64 amountStr, bytes calldata inputProof) public {
        require(!isBlacklisted[msg.sender], "Sender blacklisted");
        require(!isBlacklisted[to], "Receiver blacklisted");

        euint64 amount = FHE.fromExternal(amountStr, inputProof);
        euint64 currentBal = balances[msg.sender];
        
        ebool canTransfer = FHE.le(amount, currentBal);
        euint64 actualTransfer = FHE.select(canTransfer, amount, FHE.asEuint64(0));

        balances[msg.sender] = FHE.sub(currentBal, actualTransfer); // [arithmetic_overflow_underflow]
        euint64 actualTransferScaled = FHE.mul(actualTransfer, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(balances[msg.sender]);

        balances[to] = FHE.add(balances[to], actualTransfer);
        FHE.allowThis(balances[to]);
    }
}