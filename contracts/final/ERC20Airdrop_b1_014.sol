// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20Airdrop_b1_014 - Confidential ERC20 with encrypted airdrop
contract ERC20Airdrop_b1_014 is ZamaEthereumConfig {
    string public name = "Airdrop Token";
    string public symbol = "ADTK";
    uint8 public decimals = 18;

    address public owner;
    euint64 private totalSupply;
    mapping(address => euint64) private balances;
    mapping(address => bool) public claimed;
    euint64 private airdropAmount;
    bool public airdropActive;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint64(100_000_000);
        balances[msg.sender] = totalSupply;
        airdropAmount = FHE.asEuint64(1000);
        airdropActive = false;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(airdropAmount);
    }

    function startAirdrop(externalEuint64 perPersonStr, bytes calldata proof) public onlyOwner {
        airdropAmount = FHE.fromExternal(perPersonStr, proof);
        airdropActive = true;
        FHE.allowThis(airdropAmount);
    }

    function stopAirdrop() public onlyOwner {
        airdropActive = false;
    }

    function claimAirdrop() public {
        require(airdropActive, "Airdrop not active");
        require(!claimed[msg.sender], "Already claimed");
        claimed[msg.sender] = true;
        balances[msg.sender] = FHE.add(balances[msg.sender], airdropAmount);
        balances[owner] = FHE.sub(balances[owner], airdropAmount); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[owner]);
    }

    function transfer(address to, externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual);
        balances[to] = FHE.add(balances[to], actual);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[to]);
    }

    function allowBalance(address viewer) public {
        FHE.allow(balances[msg.sender], viewer);
    }
}
