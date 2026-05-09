// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiPrivateYieldAggregator
/// @notice Multi-pool yield aggregator with encrypted allocation weights per strategy.
///         Users deposit and the contract silently rebalances among encrypted strategies
///         without revealing individual strategy performance until harvest.
contract DeFiPrivateYieldAggregator is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    uint256 public constant MAX_STRATEGIES = 5;

    struct Strategy {
        string name;
        euint16 allocationBps; // encrypted % allocation out of 10000
        euint64 deposited;
        euint64 earned;
        bool active;
    }

    struct UserDeposit {
        euint64 amount;
        euint64 shares;
        uint256 depositTime;
    }

    mapping(uint256 => Strategy) private strategies;
    uint256 public strategyCount;
    mapping(address => UserDeposit) private userDeposits;
    euint64 private _totalDeposited;
    euint64 private _totalShares;
    euint64 private _performanceFeesBps;

    event StrategyAdded(uint256 indexed id, string name);
    event Deposited(address indexed user);
    event Harvested(address indexed user);
    event Rebalanced();

    constructor(externalEuint64 encPerfFee, bytes memory proof) Ownable(msg.sender) {
        _performanceFeesBps = FHE.fromExternal(encPerfFee, proof);
        _totalDeposited = FHE.asEuint64(0);
        _totalShares = FHE.asEuint64(0);
        FHE.allowThis(_performanceFeesBps);
        FHE.allowThis(_totalDeposited);
        FHE.allowThis(_totalShares);
    }

    function addStrategy(string calldata name, externalEuint16 encAlloc, bytes calldata proof) external onlyOwner {
        require(strategyCount < MAX_STRATEGIES, "Max strategies");
        uint256 id = strategyCount++;
        strategies[id].name = name;
        strategies[id].allocationBps = FHE.fromExternal(encAlloc, proof);
        strategies[id].deposited = FHE.asEuint64(0);
        strategies[id].earned = FHE.asEuint64(0);
        strategies[id].active = true;
        FHE.allowThis(strategies[id].allocationBps);
        FHE.allowThis(strategies[id].deposited);
        FHE.allowThis(strategies[id].earned);
        emit StrategyAdded(id, name);
    }

    function deposit(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Shares = amount (simplified 1:1 initially)
        euint64 newShares = amount;
        userDeposits[msg.sender].amount = FHE.add(userDeposits[msg.sender].amount, amount);
        userDeposits[msg.sender].shares = FHE.add(userDeposits[msg.sender].shares, newShares);
        userDeposits[msg.sender].depositTime = block.timestamp;
        _totalDeposited = FHE.add(_totalDeposited, amount);
        _totalShares = FHE.add(_totalShares, newShares);
        FHE.allowThis(userDeposits[msg.sender].amount);
        FHE.allow(userDeposits[msg.sender].amount, msg.sender);
        FHE.allowThis(userDeposits[msg.sender].shares);
        FHE.allow(userDeposits[msg.sender].shares, msg.sender);
        FHE.allowThis(_totalDeposited);
        FHE.allowThis(_totalShares);
        emit Deposited(msg.sender);
    }

    function recordYield(uint256 strategyId, externalEuint64 encYield, bytes calldata proof) external onlyOwner {
        require(strategyId < strategyCount, "Invalid strategy");
        euint64 yield = FHE.fromExternal(encYield, proof);
        strategies[strategyId].earned = FHE.add(strategies[strategyId].earned, yield);
        _totalDeposited = FHE.add(_totalDeposited, yield);
        FHE.allowThis(strategies[strategyId].earned);
        FHE.allowThis(_totalDeposited);
    }

    function rebalance(uint256[] calldata strategyIds, externalEuint16[] calldata encAllocs, bytes[] calldata proofs) external onlyOwner {
        require(strategyIds.length == encAllocs.length && encAllocs.length == proofs.length, "Length mismatch");
        for (uint256 i = 0; i < strategyIds.length; i++) {
            strategies[strategyIds[i]].allocationBps = FHE.fromExternal(encAllocs[i], proofs[i]);
            FHE.allowThis(strategies[strategyIds[i]].allocationBps);
        }
        emit Rebalanced();
    }

    function harvest(externalEuint64 encShares, bytes calldata proof) external nonReentrant {
        euint64 shares = FHE.fromExternal(encShares, proof);
        UserDeposit storage ud = userDeposits[msg.sender];
        ebool hasShares = FHE.le(shares, ud.shares);
        euint64 actual = FHE.select(hasShares, shares, FHE.asEuint64(0));
        // Simplified: return proportional amount
        euint64 returned = actual;
        ud.shares = FHE.sub(ud.shares, actual);
        ud.amount = FHE.sub(ud.amount, actual);
        _totalShares = FHE.sub(_totalShares, actual);
        _totalDeposited = FHE.sub(_totalDeposited, actual);
        FHE.allowThis(ud.shares);
        FHE.allow(ud.shares, msg.sender);
        FHE.allowThis(ud.amount);
        FHE.allow(ud.amount, msg.sender);
        FHE.allow(returned, msg.sender);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_totalDeposited);
        emit Harvested(msg.sender);
    }

    function allowUserDeposit(address viewer) external {
        FHE.allow(userDeposits[msg.sender].amount, viewer);
        FHE.allow(userDeposits[msg.sender].shares, viewer);
    }

    function allowStrategyData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(strategies[id].allocationBps, viewer);
        FHE.allow(strategies[id].deposited, viewer);
        FHE.allow(strategies[id].earned, viewer);
    }
}
