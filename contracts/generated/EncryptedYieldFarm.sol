// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedYieldFarm - Private yield farming with encrypted stake amounts and rewards
contract EncryptedYieldFarm is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct StakeInfo {
        euint64 amount;
        uint256 depositBlock;
        euint64 pendingRewards;
    }

    mapping(address => StakeInfo) public stakes;
    euint64 private totalStaked;
    euint64 private rewardPool;
    uint64 public rewardPerBlock;
    uint256 public lastRewardBlock;
    bool public farmActive;

    event Staked(address indexed user);
    event Unstaked(address indexed user);
    event RewardsAdded();
    event RewardsClaimed(address indexed user);

    constructor(uint64 _rewardPerBlock) Ownable(msg.sender) {
        rewardPerBlock = _rewardPerBlock;
        lastRewardBlock = block.number;
        totalStaked = FHE.asEuint64(0);
        rewardPool = FHE.asEuint64(0);
        FHE.allowThis(totalStaked);
        FHE.allowThis(rewardPool);
        farmActive = true;
    }

    function addRewards(externalEuint64 calldata encAmount, bytes calldata inputProof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        rewardPool = FHE.add(rewardPool, amount);
        FHE.allowThis(rewardPool);
        emit RewardsAdded();
    }

    function stake(externalEuint64 calldata encAmount, bytes calldata inputProof) external nonReentrant {
        require(farmActive, "Farm not active");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        StakeInfo storage s = stakes[msg.sender];
        s.amount = FHE.add(s.amount, amount);
        s.depositBlock = block.number;
        if (s.pendingRewards.unwrap() == 0) {
            s.pendingRewards = FHE.asEuint64(0);
        }
        totalStaked = FHE.add(totalStaked, amount);
        FHE.allowThis(s.amount);
        FHE.allowThis(s.pendingRewards);
        FHE.allowThis(totalStaked);
        FHE.allow(s.amount, msg.sender);
        emit Staked(msg.sender);
    }

    function claimRewards() external nonReentrant {
        StakeInfo storage s = stakes[msg.sender];
        uint256 blocksElapsed = block.number - s.depositBlock;
        euint64 earned = FHE.mul(s.amount, FHE.asEuint64(uint64(blocksElapsed) * rewardPerBlock / 1e6));
        s.pendingRewards = FHE.add(s.pendingRewards, earned);
        s.depositBlock = block.number;

        euint64 claimable = s.pendingRewards;
        s.pendingRewards = FHE.asEuint64(0);
        rewardPool = FHE.sub(rewardPool, claimable);

        FHE.allowThis(s.pendingRewards);
        FHE.allowThis(rewardPool);
        FHE.allow(claimable, msg.sender);
        emit RewardsClaimed(msg.sender);
    }

    function unstake(externalEuint64 calldata encAmount, bytes calldata inputProof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        StakeInfo storage s = stakes[msg.sender];
        s.amount = FHE.sub(s.amount, amount);
        totalStaked = FHE.sub(totalStaked, amount);
        FHE.allowThis(s.amount);
        FHE.allowThis(totalStaked);
        FHE.allow(s.amount, msg.sender);
        FHE.allowTransient(amount, msg.sender);
        emit Unstaked(msg.sender);
    }

    function setFarmActive(bool _active) external onlyOwner {
        farmActive = _active;
    }
}
