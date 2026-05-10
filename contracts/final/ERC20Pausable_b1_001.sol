// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ERC20Pausable_b1_001 is ZamaEthereumConfig {
    string public name = "Confidential Pausable Token";
    string public symbol = "CPTK";
    uint8 public decimals = 6;
    
    euint32 private totalSupply;
    mapping(address => euint32) private balances;
    mapping(address => mapping(address => euint32)) private allowances;
    
    bool public paused;
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint32(1000000);
        balances[msg.sender] = totalSupply;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
    }

    function pause() public onlyOwner {
        paused = true;
    }

    function unpause() public onlyOwner {
        paused = false;
    }

    function transfer(
        address to,
        externalEuint32 amountStr,
        bytes calldata inputProof
    ) public whenNotPaused {
        euint32 amount = FHE.fromExternal(amountStr, inputProof);
        euint32 currentBal = balances[msg.sender];
        
        ebool canTransfer = FHE.le(amount, currentBal);
        euint32 actualTransfer = FHE.select(canTransfer, amount, FHE.asEuint32(0));

        balances[msg.sender] = FHE.sub(currentBal, actualTransfer); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(balances[msg.sender]);

        euint32 toBal = balances[to];
        balances[to] = FHE.add(toBal, actualTransfer);
        FHE.allowThis(balances[to]);
    }

    function approve(address spender, externalEuint32 amountStr, bytes calldata inputProof) public whenNotPaused {
        euint32 amount = FHE.fromExternal(amountStr, inputProof);
        allowances[msg.sender][spender] = amount;
        FHE.allowThis(amount);
    }
}