// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateDeFiYieldFarming
/// @notice Multi-pool yield farm with encrypted APR per pool, encrypted TVL caps,
///         encrypted pending rewards, and anti-whale deposit limits enforced privately.
contract PrivateDeFiYieldFarming is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct FarmPool {
        string poolName;
        string lpTokenSymbol;
        euint64 tvlCap;               // encrypted max TVL allowed
        euint64 currentTVL;           // encrypted current deposits
        euint16 aprBps;               // encrypted APR
        euint64 rewardPerBlock;       // encrypted rewards per block
        euint64 totalRewardsPaid;     // encrypted cumulative rewards
        euint64 whaleDepositLimitBps; // encrypted max single deposit as % of cap
        uint256 startBlock;
        uint256 endBlock;
        bool active;
    }

    struct UserFarmPosition {
        euint64 depositedAmount;   // encrypted deposit
        euint64 rewardDebt;        // encrypted accounting debt (for reward calculation)
        euint64 pendingRewards;    // encrypted pending
        uint256 lastInteractionBlock;
        bool active;
    }

    mapping(uint256 => FarmPool) private pools;
    mapping(uint256 => mapping(address => UserFarmPosition)) private positions;
    mapping(uint256 => euint64) private _poolAccRewardPerShare; // accumulated reward per share * 1e12
    uint256 public poolCount;
    euint64 private _totalRewardBudget;
    address public rewardDistributor;
    mapping(address => bool) public isFarmAdmin;

    event PoolCreated(uint256 indexed id, string name);
    event Deposited(uint256 indexed poolId, address user);
    event Withdrawn(uint256 indexed poolId, address user);
    event RewardsClaimed(uint256 indexed poolId, address user);
    event PoolEnded(uint256 indexed poolId);

    constructor(address distributor) Ownable(msg.sender) {
        rewardDistributor = distributor;
        _totalRewardBudget = FHE.asEuint64(0);
        FHE.allowThis(_totalRewardBudget);
        isFarmAdmin[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isFarmAdmin[a] = true; }

    function createPool(
        string calldata name, string calldata lpSymbol,
        externalEuint64 encTVLCap, bytes calldata tcProof,
        externalEuint16 encAPR, bytes calldata aprProof,
        externalEuint64 encRewardPerBlock, bytes calldata rpbProof,
        externalEuint64 encWhaleLimit, bytes calldata wlProof,
        uint256 durationBlocks
    ) external returns (uint256 id) {
        require(isFarmAdmin[msg.sender], "Not admin");
        euint64 tvlCap = FHE.fromExternal(encTVLCap, tcProof);
        euint16 apr = FHE.fromExternal(encAPR, aprProof);
        euint64 rewardPB = FHE.fromExternal(encRewardPerBlock, rpbProof);
        euint64 whaleLimit = FHE.fromExternal(encWhaleLimit, wlProof);
        id = poolCount++;
        pools[id] = FarmPool({
            poolName: name, lpTokenSymbol: lpSymbol, tvlCap: tvlCap, currentTVL: FHE.asEuint64(0),
            aprBps: apr, rewardPerBlock: rewardPB, totalRewardsPaid: FHE.asEuint64(0),
            whaleDepositLimitBps: whaleLimit, startBlock: block.number,
            endBlock: block.number + durationBlocks, active: true
        });
        _poolAccRewardPerShare[id] = FHE.asEuint64(0);
        FHE.allowThis(pools[id].tvlCap);
        FHE.allowThis(pools[id].currentTVL);
        FHE.allowThis(pools[id].aprBps);
        FHE.allowThis(pools[id].rewardPerBlock);
        FHE.allowThis(pools[id].totalRewardsPaid);
        FHE.allowThis(pools[id].whaleDepositLimitBps);
        FHE.allowThis(_poolAccRewardPerShare[id]);
        emit PoolCreated(id, name);
    }

    function deposit(uint256 poolId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        FarmPool storage pool = pools[poolId];
        require(pool.active && block.number < pool.endBlock, "Pool inactive");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Anti-whale: max deposit = cap * whaleLimit / 10000
        euint64 maxDeposit = FHE.div(FHE.mul(pool.tvlCap, pool.whaleDepositLimitBps), 10000);
        ebool withinWhaleLimit = FHE.le(amount, maxDeposit);
        euint64 accepted = FHE.select(withinWhaleLimit, amount, maxDeposit);
        // TVL cap check
        ebool withinCap = FHE.le(FHE.add(pool.currentTVL, accepted), pool.tvlCap);
        accepted = FHE.select(withinCap, accepted, FHE.sub(pool.tvlCap, pool.currentTVL));
        pool.currentTVL = FHE.add(pool.currentTVL, accepted);
        UserFarmPosition storage pos = positions[poolId][msg.sender];
        if (!FHE.isInitialized(pos.depositedAmount)) {
            pos.depositedAmount = FHE.asEuint64(0);
            pos.rewardDebt = FHE.asEuint64(0);
            pos.pendingRewards = FHE.asEuint64(0);
            pos.lastInteractionBlock = block.number;
            FHE.allowThis(pos.depositedAmount);
            FHE.allowThis(pos.rewardDebt);
            FHE.allowThis(pos.pendingRewards);
        }
        // Accrue pending rewards before updating deposit
        _accrue(poolId, msg.sender);
        pos.depositedAmount = FHE.add(pos.depositedAmount, accepted);
        pos.lastInteractionBlock = block.number;
        pos.active = true;
        FHE.allowThis(pos.depositedAmount);
        FHE.allow(pos.depositedAmount, msg.sender);
        FHE.allowThis(pool.currentTVL);
        emit Deposited(poolId, msg.sender);
    }

    function _accrue(uint256 poolId, address user) internal {
        UserFarmPosition storage pos = positions[poolId][user];
        FarmPool storage pool = pools[poolId];
        if (!FHE.isInitialized(pos.depositedAmount)) return;
        uint256 blocks = block.number - pos.lastInteractionBlock;
        euint64 blockReward = FHE.mul(pool.rewardPerBlock, FHE.asEuint64(uint64(blocks)));
        // Approximate: user share = blockReward * depositedAmount / 1_000_000 (scaled)
        euint64 userShare = FHE.div(FHE.mul(blockReward, pos.depositedAmount), 1_000_000);
        pos.pendingRewards = FHE.add(pos.pendingRewards, userShare);
        FHE.allowThis(pos.pendingRewards);
        FHE.allow(pos.pendingRewards, user);
    }

    function claimRewards(uint256 poolId) external nonReentrant {
        _accrue(poolId, msg.sender);
        UserFarmPosition storage pos = positions[poolId][msg.sender];
        euint64 reward = pos.pendingRewards;
        pos.pendingRewards = FHE.asEuint64(0);
        pos.lastInteractionBlock = block.number;
        pools[poolId].totalRewardsPaid = FHE.add(pools[poolId].totalRewardsPaid, reward);
        FHE.allowThis(pos.pendingRewards);
        FHE.allow(reward, msg.sender);
        FHE.allowThis(pools[poolId].totalRewardsPaid);
        emit RewardsClaimed(poolId, msg.sender);
    }

    function withdraw(uint256 poolId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        _accrue(poolId, msg.sender);
        UserFarmPosition storage pos = positions[poolId][msg.sender];
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasSuf = FHE.le(amount, pos.depositedAmount);
        euint64 actual = FHE.select(hasSuf, amount, pos.depositedAmount);
        pos.depositedAmount = FHE.sub(pos.depositedAmount, actual);
        pools[poolId].currentTVL = FHE.sub(pools[poolId].currentTVL, actual);
        FHE.allowThis(pos.depositedAmount);
        FHE.allow(pos.depositedAmount, msg.sender);
        FHE.allowThis(pools[poolId].currentTVL);
        FHE.allow(actual, msg.sender);
        emit Withdrawn(poolId, msg.sender);
    }

    function endPool(uint256 poolId) external {
        require(isFarmAdmin[msg.sender], "Not admin");
        pools[poolId].active = false;
        emit PoolEnded(poolId);
    }

    function allowPoolStats(uint256 id, address viewer) external {
        require(isFarmAdmin[msg.sender], "Not admin");
        FHE.allow(pools[id].tvlCap, viewer);
        FHE.allow(pools[id].currentTVL, viewer);
        FHE.allow(pools[id].aprBps, viewer);
    }
}
