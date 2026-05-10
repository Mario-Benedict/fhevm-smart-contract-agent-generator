// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20Mintable_b1_007 - Confidential ERC20 with minting by minters
contract ERC20Mintable_b1_007 is ZamaEthereumConfig {
    string public name = "Mintable Confidential";
    string public symbol = "MCTK";
    uint8 public decimals = 8;

    address public owner;
    euint32 private totalSupply;
    mapping(address => euint32) private balances;
    mapping(address => bool) public minters;

    event MinterAdded(address indexed account);
    event MinterRemoved(address indexed account);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyMinter() {
        require(minters[msg.sender] || msg.sender == owner, "Not minter");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint32(0);
        FHE.allowThis(totalSupply);
    }

    function addMinter(address account) public onlyOwner {
        minters[account] = true;
        emit MinterAdded(account);
    }

    function removeMinter(address account) public onlyOwner {
        minters[account] = false;
        emit MinterRemoved(account);
    }

    function mint(address to, externalEuint32 amountStr, bytes calldata proof) public onlyMinter {
        euint32 amount = FHE.fromExternal(amountStr, proof);
        totalSupply = FHE.add(totalSupply, amount);
        balances[to] = FHE.add(balances[to], amount);
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[to]);
    }

    function burn(externalEuint32 amountStr, bytes calldata proof) public {
        euint32 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint32 actual = FHE.select(ok, amount, FHE.asEuint32(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        totalSupply = FHE.sub(totalSupply, actual);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(totalSupply);
    }

    function transfer(address to, externalEuint32 amountStr, bytes calldata proof) public {
        euint32 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint32 actual = FHE.select(ok, amount, FHE.asEuint32(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual);
        balances[to] = FHE.add(balances[to], actual);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[to]);
    }

    function allowBalance(address viewer) public {
        FHE.allow(balances[msg.sender], viewer);
    }
}
