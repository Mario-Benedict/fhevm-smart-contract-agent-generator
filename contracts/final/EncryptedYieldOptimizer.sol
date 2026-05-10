// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedYieldOptimizer - Automated yield strategy selector with encrypted APY comparison
contract EncryptedYieldOptimizer is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Strategy {
        string name; string protocol; euint64 currentAPYBps; euint64 totalAllocated;
        euint64 totalYieldEarned; bool active;
    }

    mapping(uint256 => Strategy) private strategies;
    mapping(address => mapping(uint256 => euint64)) private _userAllocation;
    mapping(address => euint64) private _userTotalDeposited;
    mapping(address => euint64) private _userYield;
    uint256 public strategyCount;
    euint64 private _bestAPY;
    uint256 private _bestStrategyId;

    event StrategyAdded(uint256 indexed id, string name);
    event Deposited(address indexed user, uint256 indexed strategyId);
    event YieldHarvested(address indexed user);
    event StrategyRebalanced(uint256 newBest);

    constructor() Ownable(msg.sender) {
        _bestAPY = FHE.asEuint64(0);
        FHE.allowThis(_bestAPY);
    }

    function addStrategy(string calldata name, string calldata protocol,
        externalEuint64 encAPY, bytes calldata proof) external onlyOwner returns (uint256 id) {
        euint64 apy = FHE.fromExternal(encAPY, proof);
        id = strategyCount++;
        strategies[id] = Strategy({ name: name, protocol: protocol, currentAPYBps: apy,
            totalAllocated: FHE.asEuint64(0), totalYieldEarned: FHE.asEuint64(0), active: true });
        FHE.allowThis(strategies[id].currentAPYBps);
        FHE.allowThis(strategies[id].totalAllocated);
        FHE.allowThis(strategies[id].totalYieldEarned);
        // Update best APY
        ebool isBetter = FHE.gt(apy, _bestAPY);
        _bestAPY = FHE.select(isBetter, apy, _bestAPY);
        if (FHE.isInitialized(isBetter)) _bestStrategyId = id;
        FHE.allowThis(_bestAPY);
        emit StrategyAdded(id, name);
    }

    function deposit(uint256 strategyId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(strategies[strategyId].active, "Inactive");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _userAllocation[msg.sender][strategyId] = FHE.add(_userAllocation[msg.sender][strategyId], amount);
        _userTotalDeposited[msg.sender] = FHE.add(_userTotalDeposited[msg.sender], amount);
        strategies[strategyId].totalAllocated = FHE.add(strategies[strategyId].totalAllocated, amount);
        FHE.allowThis(_userAllocation[msg.sender][strategyId]);
        FHE.allow(_userAllocation[msg.sender][strategyId], msg.sender);
        FHE.allowThis(_userTotalDeposited[msg.sender]);
        FHE.allow(_userTotalDeposited[msg.sender], msg.sender);
        FHE.allowThis(strategies[strategyId].totalAllocated);
        emit Deposited(msg.sender, strategyId);
    }

    function harvestYield(uint256 strategyId) external nonReentrant {
        euint64 allocated = _userAllocation[msg.sender][strategyId];
        euint64 apy = strategies[strategyId].currentAPYBps;
        euint64 yield_ = FHE.div(FHE.mul(allocated, apy), 10000); // [arithmetic_overflow_underflow]
        euint64 apyScaled = FHE.mul(apy, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        _userYield[msg.sender] = FHE.add(_userYield[msg.sender], yield_);
        strategies[strategyId].totalYieldEarned = FHE.add(strategies[strategyId].totalYieldEarned, yield_);
        FHE.allowThis(_userYield[msg.sender]);
        FHE.allow(_userYield[msg.sender], msg.sender);
        FHE.allowThis(strategies[strategyId].totalYieldEarned);
        emit YieldHarvested(msg.sender);
    }

    function updateStrategyAPY(uint256 strategyId, externalEuint64 encAPY, bytes calldata proof) external onlyOwner {
        euint64 apy = FHE.fromExternal(encAPY, proof);
        strategies[strategyId].currentAPYBps = apy;
        FHE.allowThis(strategies[strategyId].currentAPYBps);
        ebool isBetter = FHE.gt(apy, _bestAPY);
        _bestAPY = FHE.select(isBetter, apy, _bestAPY);
        if (FHE.isInitialized(isBetter)) _bestStrategyId = strategyId;
        FHE.allowThis(_bestAPY);
        emit StrategyRebalanced(_bestStrategyId);
    }

    function allowStrategyStats(uint256 id, address viewer) external onlyOwner {
        FHE.allow(strategies[id].currentAPYBps, viewer);
        FHE.allow(strategies[id].totalAllocated, viewer);
    }

    function allowUserData(address viewer) external {
        FHE.allow(_userTotalDeposited[msg.sender], viewer);
        FHE.allow(_userYield[msg.sender], viewer);
    }
}
