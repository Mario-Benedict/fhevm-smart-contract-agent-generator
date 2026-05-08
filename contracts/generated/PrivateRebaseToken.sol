// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateRebaseToken
/// @notice Elastic supply token with encrypted balances and rebase mechanism
contract PrivateRebaseToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "Private Rebase Token";
    string public symbol = "PRBT";
    uint8 public decimals = 18;

    mapping(address => euint64) private _shares;
    euint64 private _totalShares;
    euint64 private _totalPooledEther;

    uint256 public lastRebaseTime;
    uint256 public rebaseInterval = 8 hours;
    uint256 public rebaseMultiplierBps = 10050; // 100.5% per interval

    address[] private _holders;
    mapping(address => bool) private _isHolder;

    event Rebase(uint256 timestamp);
    event Deposit(address indexed user);
    event Withdrawal(address indexed user);

    constructor() Ownable(msg.sender) {
        _totalShares = FHE.asEuint64(0);
        FHE.allowThis(_totalShares);
        _totalPooledEther = FHE.asEuint64(0);
        FHE.allowThis(_totalPooledEther);
        lastRebaseTime = block.timestamp;
    }

    function deposit(externalEuint64 calldata encAmount, bytes calldata inputProof)
        external nonReentrant
    {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);

        // shares = amount * totalShares / totalPooledEther (or 1:1 if first deposit)
        euint64 sharesToMint = amount; // simplified 1:1 initial ratio
        _shares[msg.sender] = FHE.add(_shares[msg.sender], sharesToMint);
        _totalShares = FHE.add(_totalShares, sharesToMint);
        _totalPooledEther = FHE.add(_totalPooledEther, amount);

        FHE.allowThis(_shares[msg.sender]);
        FHE.allow(_shares[msg.sender], msg.sender);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_totalPooledEther);

        if (!_isHolder[msg.sender]) {
            _holders.push(msg.sender);
            _isHolder[msg.sender] = true;
        }
        emit Deposit(msg.sender);
    }

    function rebase() external {
        require(block.timestamp >= lastRebaseTime + rebaseInterval, "Too early");
        // Increase total pooled by rebase multiplier
        euint64 increase = FHE.div(FHE.mul(_totalPooledEther, uint64(rebaseMultiplierBps - 10000)), 10000);
        _totalPooledEther = FHE.add(_totalPooledEther, increase);
        FHE.allowThis(_totalPooledEther);

        lastRebaseTime = block.timestamp;
        emit Rebase(block.timestamp);
    }

    function withdraw(externalEuint64 calldata encShares, bytes calldata inputProof)
        external nonReentrant
    {
        euint64 shares = FHE.fromExternal(encShares, inputProof);
        ebool sufficient = FHE.ge(_shares[msg.sender], shares);
        euint64 actualShares = FHE.select(sufficient, shares, FHE.asEuint64(0));

        _shares[msg.sender] = FHE.sub(_shares[msg.sender], actualShares);
        _totalShares = FHE.sub(_totalShares, actualShares);
        // pooled amount withdrawn is proportional
        _totalPooledEther = FHE.sub(_totalPooledEther, actualShares);

        FHE.allowThis(_shares[msg.sender]);
        FHE.allow(_shares[msg.sender], msg.sender);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_totalPooledEther);

        emit Withdrawal(msg.sender);
    }

    function transfer(address to, externalEuint64 calldata encShares, bytes calldata inputProof) external {
        euint64 shares = FHE.fromExternal(encShares, inputProof);
        ebool sufficient = FHE.ge(_shares[msg.sender], shares);
        euint64 actual = FHE.select(sufficient, shares, FHE.asEuint64(0));

        _shares[msg.sender] = FHE.sub(_shares[msg.sender], actual);
        _shares[to] = FHE.add(_shares[to], actual);

        FHE.allowThis(_shares[msg.sender]);
        FHE.allow(_shares[msg.sender], msg.sender);
        FHE.allowThis(_shares[to]);
        FHE.allow(_shares[to], to);

        if (!_isHolder[to]) {
            _holders.push(to);
            _isHolder[to] = true;
        }
    }

    function sharesOf(address account) external view returns (euint64) {
        return _shares[account];
    }

    function setRebaseMultiplier(uint256 bps) external onlyOwner {
        require(bps >= 10000 && bps <= 11000, "Invalid multiplier");
        rebaseMultiplierBps = bps;
    }
}
