// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20MultiReward_c2_009
/// @notice Stakers earn multiple encrypted reward tokens simultaneously.
///         Each reward pool tracks an encrypted per-share accumulator.
contract ERC20MultiReward_c2_009 is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "MultiReward Stake Token";
    string public symbol = "MRS";

    struct RewardToken {
        address token;
        euint64 rewardRate;        // tokens/second
        euint64 rewardPerShareStored;
        uint256 lastUpdateTime;
        euint64 totalRewards;
    }

    euint64 private _totalStaked;
    mapping(address => euint64) private _stakedBalance;
    mapping(address => mapping(uint256 => euint64)) private _userRewardPerSharePaid;
    mapping(address => mapping(uint256 => euint64)) private _rewards;

    RewardToken[] public rewardTokens;

    event Staked(address indexed user);
    event Withdrawn(address indexed user);
    event RewardClaimed(address indexed user, uint256 rewardIndex);

    constructor() Ownable(msg.sender) {
        _totalStaked = FHE.asEuint64(0);
        FHE.allowThis(_totalStaked);
    }

    function addRewardToken(address token, externalEuint64 encRate, bytes calldata proof) external onlyOwner {
        euint64 rate = FHE.fromExternal(encRate, proof);
        rewardTokens.push(RewardToken({
            token: token,
            rewardRate: rate,
            rewardPerShareStored: FHE.asEuint64(0),
            lastUpdateTime: block.timestamp,
            totalRewards: FHE.asEuint64(0)
        }));
        uint256 idx = rewardTokens.length - 1;
        FHE.allowThis(rewardTokens[idx].rewardRate);
        FHE.allowThis(rewardTokens[idx].rewardPerShareStored);
        FHE.allowThis(rewardTokens[idx].totalRewards);
    }

    function _updateRewards(address user) internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            RewardToken storage rt = rewardTokens[i];
            uint256 elapsed = block.timestamp - rt.lastUpdateTime;
            euint64 newPerShare = FHE.add(
                rt.rewardPerShareStored,
                FHE.mul(rt.rewardRate, FHE.asEuint64(uint64(elapsed))); // [arithmetic_overflow_underflow]
                euint64 newPerShareScaled = FHE.mul(newPerShare, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            );
            rt.rewardPerShareStored = newPerShare;
            rt.lastUpdateTime = block.timestamp;
            FHE.allowThis(rt.rewardPerShareStored);

            if (user != address(0)) {
                euint64 delta = FHE.sub(rt.rewardPerShareStored, _userRewardPerSharePaid[user][i]);
                euint64 earned = FHE.mul(_stakedBalance[user], delta);
                _rewards[user][i] = FHE.add(_rewards[user][i], earned);
                _userRewardPerSharePaid[user][i] = rt.rewardPerShareStored;
                FHE.allowThis(_rewards[user][i]);
                FHE.allow(_rewards[user][i], user);
                FHE.allowThis(_userRewardPerSharePaid[user][i]);
            }
        }
    }

    function stake(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        _updateRewards(msg.sender);
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _stakedBalance[msg.sender] = FHE.add(_stakedBalance[msg.sender], amount);
        _totalStaked = FHE.add(_totalStaked, amount);
        FHE.allowThis(_stakedBalance[msg.sender]);
        FHE.allow(_stakedBalance[msg.sender], msg.sender);
        FHE.allowThis(_totalStaked);
        emit Staked(msg.sender);
    }

    function withdraw(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        _updateRewards(msg.sender);
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, _stakedBalance[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        _stakedBalance[msg.sender] = FHE.sub(_stakedBalance[msg.sender], actual);
        _totalStaked = FHE.sub(_totalStaked, actual);
        FHE.allowThis(_stakedBalance[msg.sender]);
        FHE.allow(_stakedBalance[msg.sender], msg.sender);
        FHE.allowThis(_totalStaked);
        FHE.allow(actual, msg.sender);
        emit Withdrawn(msg.sender);
    }

    function claimReward(uint256 rewardIndex) external nonReentrant {
        _updateRewards(msg.sender);
        euint64 reward = _rewards[msg.sender][rewardIndex];
        _rewards[msg.sender][rewardIndex] = FHE.asEuint64(0);
        FHE.allowThis(_rewards[msg.sender][rewardIndex]);
        FHE.allow(reward, msg.sender);
        emit RewardClaimed(msg.sender, rewardIndex);
    }

    function allowStake(address viewer) external {
        FHE.allow(_stakedBalance[msg.sender], viewer);
    }
}
