// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title StakingLiquidityMining_b4_005 - Encrypted liquidity mining rewards
contract StakingLiquidityMining_b4_005 is ZamaEthereumConfig {
    address public owner;
    euint64 private rewardPool;
    euint64 private totalStaked;
    mapping(address => euint64) private stakes;
    mapping(address => uint256) private stakeTimestamp;
    mapping(address => euint64) private pendingRewards;
    uint64 public rewardPerSecondPerUnit; // plaintext reward rate

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint64 _rewardRate) {
        owner = msg.sender;
        rewardPerSecondPerUnit = _rewardRate;
        rewardPool = FHE.asEuint64(0);
        totalStaked = FHE.asEuint64(0);
        FHE.allowThis(rewardPool);
        FHE.allowThis(totalStaked);
    }

    function fundRewards(externalEuint64 amountStr, bytes calldata proof) public onlyOwner {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        rewardPool = FHE.add(rewardPool, amount);
        FHE.allowThis(rewardPool);
    }

    function stake(externalEuint64 amountStr, bytes calldata proof) public {
        _claimRewards();
        euint64 amount = FHE.fromExternal(amountStr, proof);
        stakes[msg.sender] = FHE.add(stakes[msg.sender], amount);
        totalStaked = FHE.add(totalStaked, amount);
        stakeTimestamp[msg.sender] = block.timestamp;
        FHE.allowThis(stakes[msg.sender]);
        FHE.allowThis(totalStaked);
    }

    function unstake(externalEuint64 amountStr, bytes calldata proof) public {
        _claimRewards();
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, stakes[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        stakes[msg.sender] = FHE.sub(stakes[msg.sender], actual);
        totalStaked = FHE.sub(totalStaked, actual);
        FHE.allowThis(stakes[msg.sender]);
        FHE.allowThis(totalStaked);
    }

    function _claimRewards() internal {
        if (stakeTimestamp[msg.sender] == 0) return;
        uint256 elapsed = block.timestamp - stakeTimestamp[msg.sender];
        euint64 reward = FHE.mul(
            stakes[msg.sender],
            FHE.asEuint64(uint64(elapsed) * rewardPerSecondPerUnit)
        );
        pendingRewards[msg.sender] = FHE.add(pendingRewards[msg.sender], reward);
        stakeTimestamp[msg.sender] = block.timestamp;
        FHE.allowThis(pendingRewards[msg.sender]);
    }

    function claimRewards() public {
        _claimRewards();
        ebool hasFunds = FHE.ge(rewardPool, pendingRewards[msg.sender]);
        euint64 payout = FHE.select(hasFunds, pendingRewards[msg.sender], rewardPool);
        rewardPool = FHE.sub(rewardPool, payout);
        pendingRewards[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(rewardPool);
        FHE.allowThis(pendingRewards[msg.sender]);
    }

    function allowStake(address viewer) public {
        FHE.allow(stakes[msg.sender], viewer);
    }
}
