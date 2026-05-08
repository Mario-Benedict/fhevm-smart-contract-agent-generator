// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateLiquidityMining - Encrypted LP token staking with confidential emission rates
contract PrivateLiquidityMining is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct MiningPool {
        string name;
        euint64 totalLPStaked;
        euint64 rewardReserve;
        euint64 emissionRatePerBlock;
        uint256 lastRewardBlock;
        uint256 allocPoints;
        bool active;
    }

    struct MinerPosition {
        euint64 lpAmount;
        euint64 rewardDebt;
        euint64 pendingRewards;
        uint256 lastDepositBlock;
        bool hasPosition;
    }

    mapping(uint256 => MiningPool) public pools;
    mapping(uint256 => mapping(address => MinerPosition)) private positions;
    uint256 public poolCount;
    uint256 public totalAllocPoints;

    event PoolAdded(uint256 indexed poolId, string name);
    event LPDeposited(uint256 indexed poolId, address indexed miner);
    event LPWithdrawn(uint256 indexed poolId, address indexed miner);
    event RewardHarvested(uint256 indexed poolId, address indexed miner);

    constructor() Ownable(msg.sender) {}

    function addPool(
        string calldata name,
        externalEuint64 calldata encEmission,
        bytes calldata inputProof,
        uint256 allocPoints
    ) external onlyOwner returns (uint256 poolId) {
        poolId = poolCount++;
        MiningPool storage p = pools[poolId];
        p.name = name;
        p.totalLPStaked = FHE.asEuint64(0);
        p.rewardReserve = FHE.asEuint64(0);
        p.emissionRatePerBlock = FHE.fromExternal(encEmission, inputProof);
        p.lastRewardBlock = block.number;
        p.allocPoints = allocPoints;
        p.active = true;
        totalAllocPoints += allocPoints;
        FHE.allowThis(p.totalLPStaked);
        FHE.allowThis(p.rewardReserve);
        FHE.allowThis(p.emissionRatePerBlock);
        emit PoolAdded(poolId, name);
    }

    function fundPool(uint256 poolId, externalEuint64 calldata encAmount, bytes calldata inputProof)
        external
        onlyOwner
    {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        pools[poolId].rewardReserve = FHE.add(pools[poolId].rewardReserve, amount);
        FHE.allowThis(pools[poolId].rewardReserve);
    }

    function deposit(uint256 poolId, externalEuint64 calldata encLPAmount, bytes calldata inputProof)
        external
        nonReentrant
    {
        MiningPool storage p = pools[poolId];
        require(p.active, "Pool inactive");
        euint64 amount = FHE.fromExternal(encLPAmount, inputProof);
        MinerPosition storage m = positions[poolId][msg.sender];
        if (!m.hasPosition) {
            m.lpAmount = FHE.asEuint64(0);
            m.rewardDebt = FHE.asEuint64(0);
            m.pendingRewards = FHE.asEuint64(0);
            m.hasPosition = true;
        }
        m.lpAmount = FHE.add(m.lpAmount, amount);
        m.lastDepositBlock = block.number;
        p.totalLPStaked = FHE.add(p.totalLPStaked, amount);
        FHE.allowThis(m.lpAmount);
        FHE.allowThis(m.pendingRewards);
        FHE.allowThis(p.totalLPStaked);
        FHE.allow(m.lpAmount, msg.sender);
        FHE.allow(m.pendingRewards, msg.sender);
        emit LPDeposited(poolId, msg.sender);
    }

    function harvest(uint256 poolId) external nonReentrant {
        MiningPool storage p = pools[poolId];
        MinerPosition storage m = positions[poolId][msg.sender];
        require(m.hasPosition, "No position");
        uint256 blocksElapsed = block.number - m.lastDepositBlock;
        euint64 earned = FHE.mul(m.lpAmount, FHE.mul(p.emissionRatePerBlock, FHE.asEuint64(uint64(blocksElapsed))));
        m.pendingRewards = FHE.add(m.pendingRewards, earned);
        euint64 payout = m.pendingRewards;
        m.pendingRewards = FHE.asEuint64(0);
        p.rewardReserve = FHE.sub(p.rewardReserve, payout);
        m.lastDepositBlock = block.number;
        FHE.allowThis(m.pendingRewards);
        FHE.allowThis(p.rewardReserve);
        FHE.allowTransient(payout, msg.sender);
        emit RewardHarvested(poolId, msg.sender);
    }

    function withdraw(uint256 poolId, externalEuint64 calldata encAmount, bytes calldata inputProof)
        external
        nonReentrant
    {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        MinerPosition storage m = positions[poolId][msg.sender];
        m.lpAmount = FHE.sub(m.lpAmount, amount);
        pools[poolId].totalLPStaked = FHE.sub(pools[poolId].totalLPStaked, amount);
        FHE.allowThis(m.lpAmount);
        FHE.allowThis(pools[poolId].totalLPStaked);
        FHE.allow(m.lpAmount, msg.sender);
        FHE.allowTransient(amount, msg.sender);
        emit LPWithdrawn(poolId, msg.sender);
    }
}
