// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20PrivacyPool_b1_020 - Privacy-preserving token pool with shielded balances
contract ERC20PrivacyPool_b1_020 is ZamaEthereumConfig {
    string public name = "Privacy Pool Token";
    string public symbol = "PRVP";
    uint8 public decimals = 18;

    address public owner;
    euint64 private poolTotal;
    mapping(bytes32 => euint64) private commitments; // shielded note storage
    mapping(address => euint64) private balances;
    euint64 private totalSupply;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint64(50_000_000);
        balances[msg.sender] = totalSupply;
        poolTotal = FHE.asEuint64(0);
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(poolTotal);
    }

    function shield(externalEuint64 amountStr, bytes calldata proof, bytes32 noteHash) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual);
        commitments[noteHash] = FHE.add(commitments[noteHash], actual);
        poolTotal = FHE.add(poolTotal, actual);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(commitments[noteHash]);
        FHE.allowThis(poolTotal);
    }

    function unshield(bytes32 noteHash, externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, commitments[noteHash]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        commitments[noteHash] = FHE.sub(commitments[noteHash], actual);
        balances[msg.sender] = FHE.add(balances[msg.sender], actual);
        poolTotal = FHE.sub(poolTotal, actual);
        FHE.allowThis(commitments[noteHash]);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(poolTotal);
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
