// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title CrimsonPeakToken - Confidential ERC20 with encrypted dividend snapshot
contract CrimsonPeakToken is ZamaEthereumConfig, Ownable {
    string public constant name = "CrimsonPeak";
    string public constant symbol = "CPK";

    mapping(address => euint64) private _balances;
    mapping(uint256 => mapping(address => euint64)) private _snapshots;
    mapping(uint256 => mapping(address => bool)) private _snapshotRecorded;
    mapping(address => uint256) private _lastClaimedSnapshot;
    uint256 public currentSnapshotId;
    euint64 private _totalDividendPool;

    event SnapshotCreated(uint256 indexed snapshotId);
    event DividendDeposited();
    event DividendClaimed(address indexed account);

    constructor() Ownable(msg.sender) {}

    function mint(address to, externalEuint64 encAmount, bytes calldata inputProof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[to] = FHE.add(_balances[to], amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function snapshot() external onlyOwner {
        currentSnapshotId++;
        emit SnapshotCreated(currentSnapshotId);
    }

    function recordSnapshot(address account) external {
        require(!_snapshotRecorded[currentSnapshotId][account], "Already recorded");
        _snapshotRecorded[currentSnapshotId][account] = true;
        _snapshots[currentSnapshotId][account] = _balances[account];
        FHE.allowThis(_snapshots[currentSnapshotId][account]);
    }

    function depositDividend(externalEuint64 encAmount, bytes calldata inputProof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _totalDividendPool = FHE.add(_totalDividendPool, amount);
        FHE.allowThis(_totalDividendPool);
        emit DividendDeposited();
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata inputProof) external {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], amount);
        _balances[to] = FHE.add(_balances[to], amount);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[to], to);
    }

    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }
}
