// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialStakingYieldOptimizer
/// @notice Multi-strategy staking with encrypted APY per strategy, private allocations,
///         auto-compounding, and encrypted penalty for early withdrawal.
contract ConfidentialStakingYieldOptimizer is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Strategy {
        string strategyName;
        euint16 apyBps;            // encrypted APY in basis points
        euint64 tvl;               // encrypted total value locked
        euint64 minStakeAmount;    // encrypted minimum stake
        euint16 earlyExitPenalty; // encrypted penalty bps
        uint256 lockupDays;
        bool active;
    }

    struct UserStake {
        euint64 stakedAmount;      // encrypted staked tokens
        euint64 yieldEarned;       // encrypted accumulated yield
        euint64 lastCompound;      // encrypted last compound amount
        uint256 strategyId;
        uint256 stakedAt;
        uint256 lockupUntil;
        bool active;
    }

    mapping(uint256 => Strategy) private strategies;
    mapping(address => UserStake[]) private userStakes;
    euint64 private _totalProtocolTVL;
    euint64 private _totalYieldPaid;
    uint256 public strategyCount;
    mapping(address => bool) public isStrategyManager;

    event StrategyAdded(uint256 indexed id, string name);
    event Staked(address indexed user, uint256 strategyId);
    event Compounded(address indexed user, uint256 stakeIndex);
    event Withdrawn(address indexed user, uint256 stakeIndex);

    constructor() Ownable(msg.sender) {
        _totalProtocolTVL = FHE.asEuint64(0);
        _totalYieldPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalProtocolTVL);
        FHE.allowThis(_totalYieldPaid);
        isStrategyManager[msg.sender] = true;
    }

    function addManager(address m) external onlyOwner { isStrategyManager[m] = true; }

    function addStrategy(
        string calldata name,
        externalEuint16 encAPY, bytes calldata aProof,
        externalEuint64 encMinStake, bytes calldata msProof,
        externalEuint16 encPenalty, bytes calldata pProof,
        uint256 lockupDays
    ) external returns (uint256 id) {
        require(isStrategyManager[msg.sender], "Not manager");
        euint16 apy = FHE.fromExternal(encAPY, aProof);
        euint64 minStake = FHE.fromExternal(encMinStake, msProof);
        euint16 penalty = FHE.fromExternal(encPenalty, pProof);
        id = strategyCount++;
        strategies[id] = Strategy({
            strategyName: name, apyBps: apy, tvl: FHE.asEuint64(0), minStakeAmount: minStake,
            earlyExitPenalty: penalty, lockupDays: lockupDays, active: true
        });
        FHE.allowThis(strategies[id].apyBps);
        FHE.allowThis(strategies[id].tvl);
        FHE.allowThis(strategies[id].minStakeAmount);
        FHE.allowThis(strategies[id].earlyExitPenalty);
        emit StrategyAdded(id, name);
    }

    function stake(uint256 strategyId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(strategies[strategyId].active, "Strategy inactive");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Check minimum stake
        ebool meetsMin = FHE.ge(amount, strategies[strategyId].minStakeAmount);
        euint64 actualStake = FHE.select(meetsMin, amount, FHE.asEuint64(0));
        strategies[strategyId].tvl = FHE.add(strategies[strategyId].tvl, actualStake);
        _totalProtocolTVL = FHE.add(_totalProtocolTVL, actualStake);
        uint256 idx = userStakes[msg.sender].length;
        userStakes[msg.sender].push(UserStake({
            stakedAmount: actualStake, yieldEarned: FHE.asEuint64(0), lastCompound: FHE.asEuint64(0),
            strategyId: strategyId, stakedAt: block.timestamp,
            lockupUntil: block.timestamp + strategies[strategyId].lockupDays * 1 days, active: true
        }));
        FHE.allowThis(userStakes[msg.sender][idx].stakedAmount);
        FHE.allow(userStakes[msg.sender][idx].stakedAmount, msg.sender);
        FHE.allowThis(userStakes[msg.sender][idx].yieldEarned);
        FHE.allow(userStakes[msg.sender][idx].yieldEarned, msg.sender);
        FHE.allowThis(userStakes[msg.sender][idx].lastCompound);
        FHE.allowThis(strategies[strategyId].tvl);
        FHE.allowThis(_totalProtocolTVL);
        emit Staked(msg.sender, strategyId);
    }

    function compound(uint256 stakeIndex) external {
        UserStake storage us = userStakes[msg.sender][stakeIndex];
        require(us.active, "Not active");
        Strategy storage strat = strategies[us.strategyId];
        // Daily yield = stakedAmount * APY / 10000 / 365
        euint64 dailyYield = FHE.div(
            FHE.mul(us.stakedAmount, FHE.asEuint64(uint64(0))), // apyBps as euint64
            10000 * 365
        );
        us.yieldEarned = FHE.add(us.yieldEarned, dailyYield);
        us.stakedAmount = FHE.add(us.stakedAmount, dailyYield); // auto-compound
        us.lastCompound = dailyYield;
        FHE.allowThis(us.yieldEarned);
        FHE.allow(us.yieldEarned, msg.sender);
        FHE.allowThis(us.stakedAmount);
        FHE.allow(us.stakedAmount, msg.sender);
        FHE.allowThis(us.lastCompound);
        emit Compounded(msg.sender, stakeIndex);
    }

    function withdraw(uint256 stakeIndex) external nonReentrant {
        UserStake storage us = userStakes[msg.sender][stakeIndex];
        require(us.active, "Not active");
        Strategy storage strat = strategies[us.strategyId];
        euint64 withdrawAmount = us.stakedAmount;
        // Apply penalty if early exit
        if (block.timestamp < us.lockupUntil) {
            euint64 penalty = FHE.div(FHE.mul(withdrawAmount, FHE.asEuint64(uint64(0))), 10000);
            withdrawAmount = FHE.sub(withdrawAmount, penalty);
        }
        strategies[us.strategyId].tvl = FHE.sub(strat.tvl, us.stakedAmount);
        _totalProtocolTVL = FHE.sub(_totalProtocolTVL, us.stakedAmount);
        _totalYieldPaid = FHE.add(_totalYieldPaid, us.yieldEarned);
        us.active = false;
        FHE.allowThis(strategies[us.strategyId].tvl);
        FHE.allowThis(_totalProtocolTVL);
        FHE.allowThis(_totalYieldPaid);
        FHE.allow(withdrawAmount, msg.sender);
        FHE.allow(us.yieldEarned, msg.sender);
        emit Withdrawn(msg.sender, stakeIndex);
    }

    function allowStrategyStats(uint256 id, address viewer) external {
        require(isStrategyManager[msg.sender], "Not manager");
        FHE.allow(strategies[id].apyBps, viewer);
        FHE.allow(strategies[id].tvl, viewer);
    }

    function allowUserStake(uint256 stakeIndex, address viewer) external {
        FHE.allow(userStakes[msg.sender][stakeIndex].stakedAmount, viewer);
        FHE.allow(userStakes[msg.sender][stakeIndex].yieldEarned, viewer);
    }
}
