// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20Snapshot_b1_008 - Confidential ERC20 with snapshot for governance
contract ERC20Snapshot_b1_008 is ZamaEthereumConfig {
    string public name = "Snapshot Token";
    string public symbol = "SNAP";
    uint8 public decimals = 18;

    address public owner;
    euint64 private totalSupply;
    mapping(address => euint64) private balances;

    uint256 public currentSnapshotId;
    mapping(uint256 => mapping(address => euint64)) private snapshotBalances;
    mapping(uint256 => bool) public snapshotExists;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint64(5_000_000);
        balances[msg.sender] = totalSupply;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
    }

    function snapshot() public onlyOwner returns (uint256) {
        currentSnapshotId++;
        snapshotExists[currentSnapshotId] = true;
        return currentSnapshotId;
    }

    function saveSnapshotBalance(uint256 snapshotId) public {
        require(snapshotExists[snapshotId], "Snapshot not found");
        snapshotBalances[snapshotId][msg.sender] = balances[msg.sender];
        FHE.allowThis(snapshotBalances[snapshotId][msg.sender]);
        FHE.allow(snapshotBalances[snapshotId][msg.sender], msg.sender);
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
