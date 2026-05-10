// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20Timelock_b1_010 - ERC20 with time-locked transfers
contract ERC20Timelock_b1_010 is ZamaEthereumConfig {
    string public name = "Timelock Token";
    string public symbol = "TLTK";
    uint8 public decimals = 18;

    address public owner;
    euint64 private totalSupply;
    mapping(address => euint64) private balances;

    struct LockedBalance {
        euint64 amount;
        uint256 unlockTime;
    }

    mapping(address => LockedBalance[]) private locks;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint64(50_000_000);
        balances[msg.sender] = totalSupply;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
    }

    function lockTokens(
        address beneficiary,
        externalEuint64 amountStr,
        bytes calldata proof,
        uint256 unlockTime
    ) public {
        require(unlockTime > block.timestamp, "Unlock must be future");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual); // [arithmetic_overflow_underflow]
        euint64 actualScaled = FHE.mul(actual, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(balances[msg.sender]);

        LockedBalance memory lb;
        lb.amount = actual;
        lb.unlockTime = unlockTime;
        FHE.allowThis(lb.amount);
        locks[beneficiary].push(lb);
    }

    function claimLocked(uint256 index) public {
        LockedBalance storage lb = locks[msg.sender][index];
        require(block.timestamp >= lb.unlockTime, "Still locked");
        euint64 amount = lb.amount;
        lb.amount = FHE.asEuint64(0);
        FHE.allowThis(lb.amount);
        balances[msg.sender] = FHE.add(balances[msg.sender], amount);
        FHE.allowThis(balances[msg.sender]);
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
