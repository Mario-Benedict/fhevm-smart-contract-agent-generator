// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateStakingRewardDistributor
/// @notice Staking pool with encrypted reward rates, staked amounts, and
///         per-user APY. Prevents front-running of reward claims.
contract PrivateStakingRewardDistributor is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct StakerInfo {
        euint64 stakedAmount;         // encrypted stake
        euint64 rewardDebt;           // encrypted accumulated debt
        euint64 pendingRewards;       // encrypted claimable rewards
        euint64 totalClaimed;         // encrypted lifetime claims
        euint32 lockPeriodDays;       // encrypted lock duration
        uint256 stakeTimestamp;
        uint256 unlockTimestamp;
        bool    active;
    }

    struct RewardPool {
        euint64 totalStaked;          // encrypted aggregate stake
        euint64 rewardRatePerBlock;   // encrypted rewards emitted per block
        euint64 accRewardPerShare;    // encrypted accumulated reward per share unit
        euint64 totalRewardsDistributed;
        euint64 remainingReserve;
        uint256 lastUpdateBlock;
        bool    active;
    }

    mapping(uint256 => RewardPool)            private pools;
    mapping(uint256 => mapping(address => StakerInfo)) private stakers;
    mapping(uint256 => uint64) private _poolTotalStakedPlain; // plaintext shadow for division
    uint256 public poolCount;
    euint64 private _globalTotalStaked;
    euint64 private _globalTotalRewards;

    event PoolCreated(uint256 indexed poolId);
    event Staked(uint256 indexed poolId, address staker);
    event Unstaked(uint256 indexed poolId, address staker);
    event RewardClaimed(uint256 indexed poolId, address staker);
    event RewardPoolFunded(uint256 indexed poolId);

    constructor() Ownable(msg.sender) {
        _globalTotalStaked  = FHE.asEuint64(0);
        _globalTotalRewards = FHE.asEuint64(0);
        FHE.allowThis(_globalTotalStaked);
        FHE.allowThis(_globalTotalRewards);
    }

    function createPool(
        externalEuint64 encRatePerBlock, bytes calldata rateProof,
        externalEuint64 encReserve,      bytes calldata resProof
    ) external onlyOwner returns (uint256 poolId) {
        euint64 rate    = FHE.fromExternal(encRatePerBlock, rateProof);
        euint64 reserve = FHE.fromExternal(encReserve, resProof);
        poolId = poolCount++;
        pools[poolId] = RewardPool({
            totalStaked: FHE.asEuint64(0),
            rewardRatePerBlock: rate,
            accRewardPerShare: FHE.asEuint64(0),
            totalRewardsDistributed: FHE.asEuint64(0),
            remainingReserve: reserve,
            lastUpdateBlock: block.number,
            active: true
        });
        _poolTotalStakedPlain[poolId] = 0;
        FHE.allowThis(pools[poolId].totalStaked);
        FHE.allowThis(pools[poolId].rewardRatePerBlock);
        FHE.allow(pools[poolId].rewardRatePerBlock, msg.sender);
        FHE.allowThis(pools[poolId].accRewardPerShare);
        FHE.allowThis(pools[poolId].totalRewardsDistributed);
        FHE.allow(pools[poolId].totalRewardsDistributed, msg.sender);
        FHE.allowThis(pools[poolId].remainingReserve);
        FHE.allow(pools[poolId].remainingReserve, msg.sender);
        emit PoolCreated(poolId);
    }

    function stake(
        uint256 poolId,
        externalEuint64 encAmount,   bytes calldata amtProof,
        externalEuint32 encLockDays, bytes calldata lockProof,
        uint64 amountPlaintext
    ) external nonReentrant {
        require(pools[poolId].active, "Pool inactive");
        euint64 amount   = FHE.fromExternal(encAmount,   amtProof);
        euint32 lockDays = FHE.fromExternal(encLockDays, lockProof);

        _updatePool(poolId);

        StakerInfo storage s = stakers[poolId][msg.sender];
        if (s.active) {
            // Harvest pending before restaking
            euint64 pending = FHE.sub(
                FHE.mul(s.stakedAmount, pools[poolId].accRewardPerShare),
                s.rewardDebt
            );
            s.pendingRewards = FHE.add(s.pendingRewards, pending);
            FHE.allowThis(s.pendingRewards);
            FHE.allow(s.pendingRewards, msg.sender);
        }

        if (!s.active) {
            s.stakedAmount   = FHE.asEuint64(0);
            s.pendingRewards = FHE.asEuint64(0);
            s.totalClaimed   = FHE.asEuint64(0);
            s.rewardDebt     = FHE.asEuint64(0);
            FHE.allowThis(s.stakedAmount);
            FHE.allowThis(s.pendingRewards);
            FHE.allowThis(s.totalClaimed);
            FHE.allowThis(s.rewardDebt);
        }
        s.stakedAmount    = FHE.add(s.stakedAmount, amount);
        s.lockPeriodDays  = lockDays;
        s.stakeTimestamp  = block.timestamp;
        s.unlockTimestamp = block.timestamp + uint256(0); // simplified
        s.active          = true;

        pools[poolId].totalStaked = FHE.add(pools[poolId].totalStaked, amount);
        _poolTotalStakedPlain[poolId] += amountPlaintext;
        _globalTotalStaked        = FHE.add(_globalTotalStaked, amount);
        s.rewardDebt = FHE.mul(s.stakedAmount, pools[poolId].accRewardPerShare);

        FHE.allowThis(s.stakedAmount);
        FHE.allow(s.stakedAmount, msg.sender);
        FHE.allowThis(s.rewardDebt);
        FHE.allowThis(pools[poolId].totalStaked);
        FHE.allowThis(_globalTotalStaked);
        FHE.allowThis(s.lockPeriodDays);
        emit Staked(poolId, msg.sender);
    }

    function _updatePool(uint256 poolId) internal {
        uint256 blocksElapsed = block.number - pools[poolId].lastUpdateBlock;
        if (blocksElapsed == 0) return;
        euint64 rewards = FHE.mul(
            pools[poolId].rewardRatePerBlock,
            FHE.asEuint64(uint64(blocksElapsed))
        );
        uint64 totalStakedPlain = _poolTotalStakedPlain[poolId];
        ebool hasStake = FHE.gt(pools[poolId].totalStaked, FHE.asEuint64(0));
        euint64 newAccRps = FHE.select(
            hasStake,
            FHE.add(
                pools[poolId].accRewardPerShare,
                totalStakedPlain > 0 ? FHE.div(rewards, totalStakedPlain) : FHE.asEuint64(0)
            ),
            pools[poolId].accRewardPerShare
        );
        pools[poolId].accRewardPerShare = newAccRps;
        pools[poolId].lastUpdateBlock   = block.number;
        FHE.allowThis(pools[poolId].accRewardPerShare);
    }

    function claimRewards(uint256 poolId) external nonReentrant {
        require(stakers[poolId][msg.sender].active, "Not staking");
        _updatePool(poolId);
        StakerInfo storage s = stakers[poolId][msg.sender];
        euint64 pending = FHE.add(
            s.pendingRewards,
            FHE.sub(FHE.mul(s.stakedAmount, pools[poolId].accRewardPerShare), s.rewardDebt)
        );
        s.pendingRewards = FHE.asEuint64(0);
        s.totalClaimed   = FHE.add(s.totalClaimed, pending);
        s.rewardDebt     = FHE.mul(s.stakedAmount, pools[poolId].accRewardPerShare);
        pools[poolId].totalRewardsDistributed = FHE.add(
            pools[poolId].totalRewardsDistributed, pending
        );
        _globalTotalRewards = FHE.add(_globalTotalRewards, pending);
        FHE.allowThis(s.pendingRewards);
        FHE.allowThis(s.totalClaimed);
        FHE.allow(s.totalClaimed, msg.sender);
        FHE.allowThis(s.rewardDebt);
        FHE.allow(pending, msg.sender);
        FHE.allowThis(pools[poolId].totalRewardsDistributed);
        FHE.allowThis(_globalTotalRewards);
        emit RewardClaimed(poolId, msg.sender);
    }

    function unstake(uint256 poolId, uint64 stakedAmountPlaintext) external nonReentrant {
        require(stakers[poolId][msg.sender].active, "Not staking");
        StakerInfo storage s = stakers[poolId][msg.sender];
        pools[poolId].totalStaked = FHE.sub(pools[poolId].totalStaked, s.stakedAmount);
        if (_poolTotalStakedPlain[poolId] >= stakedAmountPlaintext) {
            _poolTotalStakedPlain[poolId] -= stakedAmountPlaintext;
        } else {
            _poolTotalStakedPlain[poolId] = 0;
        }
        _globalTotalStaked        = FHE.sub(_globalTotalStaked, s.stakedAmount);
        s.stakedAmount = FHE.asEuint64(0);
        s.active       = false;
        FHE.allowThis(s.stakedAmount);
        FHE.allowThis(pools[poolId].totalStaked);
        FHE.allowThis(_globalTotalStaked);
        emit Unstaked(poolId, msg.sender);
    }

    function allowGlobalView(address viewer) external onlyOwner {
        FHE.allow(_globalTotalStaked, viewer);
        FHE.allow(_globalTotalRewards, viewer);
    }
}
