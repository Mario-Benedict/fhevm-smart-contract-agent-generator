// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateYieldFarmingPool
/// @notice Encrypted yield farm: hidden user stake amounts, private reward rates per epoch,
///         confidential boost multipliers, and encrypted harvest amounts.
contract PrivateYieldFarmingPool is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct UserStake {
        euint64 stakedAmount;          // encrypted stake
        euint64 pendingRewards;        // encrypted unclaimed rewards
        euint64 boostMultiplierBps;    // encrypted boost (10000 = 1x)
        uint256 lastClaimEpoch;
        uint256 stakeStart;
        bool active;
    }

    struct Epoch {
        uint256 epochId;
        euint64 totalRewardPool;       // encrypted epoch reward pool
        euint64 totalStaked;           // encrypted total staked in epoch
        euint64 rewardPerStakeUnit;    // encrypted reward per unit
        uint256 startTime;
        uint256 endTime;
    }

    mapping(address => UserStake) private stakes;
    mapping(uint256 => Epoch) private epochs;
    uint256 public epochCount;
    uint256 public currentEpoch;
    euint64 private _totalProtocolRewards;
    euint64 private _totalStaked;

    event EpochStarted(uint256 indexed epochId);
    event Staked(address indexed user, uint256 timestamp);
    event Harvested(address indexed user, uint256 epochId);
    event Unstaked(address indexed user, uint256 timestamp);

    constructor() Ownable(msg.sender) {
        _totalProtocolRewards = FHE.asEuint64(0);
        _totalStaked = FHE.asEuint64(0);
        FHE.allowThis(_totalProtocolRewards);
        FHE.allowThis(_totalStaked);
    }

    function startEpoch(externalEuint64 encRewardPool, bytes calldata proof, uint256 durationHours) external onlyOwner returns (uint256 id) {
        euint64 rewardPool = FHE.fromExternal(encRewardPool, proof);
        euint64 rewardPoolWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 rewardPoolExposure = FHE.sub(rewardPoolWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        id = epochCount++;
        currentEpoch = id;
        epochs[id] = Epoch({
            epochId: id, totalRewardPool: rewardPool, totalStaked: _totalStaked,
            rewardPerStakeUnit: FHE.asEuint64(0), startTime: block.timestamp,
            endTime: block.timestamp + durationHours * 1 hours
        });
        _totalProtocolRewards = FHE.add(_totalProtocolRewards, rewardPool);
        FHE.allowThis(epochs[id].totalRewardPool); FHE.allowThis(epochs[id].totalStaked);
        FHE.allowThis(epochs[id].rewardPerStakeUnit); FHE.allowThis(_totalProtocolRewards);
        emit EpochStarted(id);
    }

    function stake(externalEuint64 encAmt, bytes calldata proof, externalEuint64 encBoost, bytes calldata bProof) external nonReentrant {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        euint64 boost = FHE.fromExternal(encBoost, bProof);
        if (!FHE.isInitialized(stakes[msg.sender].stakedAmount)) {
            stakes[msg.sender] = UserStake({
                stakedAmount: FHE.asEuint64(0), pendingRewards: FHE.asEuint64(0),
                boostMultiplierBps: boost, lastClaimEpoch: currentEpoch,
                stakeStart: block.timestamp, active: true
            });
            FHE.allowThis(stakes[msg.sender].stakedAmount); FHE.allow(stakes[msg.sender].stakedAmount, msg.sender);
            FHE.allowThis(stakes[msg.sender].pendingRewards); FHE.allow(stakes[msg.sender].pendingRewards, msg.sender);
            FHE.allowThis(stakes[msg.sender].boostMultiplierBps); FHE.allow(stakes[msg.sender].boostMultiplierBps, msg.sender);
        }
        stakes[msg.sender].stakedAmount = FHE.add(stakes[msg.sender].stakedAmount, amt);
        _totalStaked = FHE.add(_totalStaked, amt);
        FHE.allowThis(stakes[msg.sender].stakedAmount); FHE.allow(stakes[msg.sender].stakedAmount, msg.sender);
        FHE.allowThis(_totalStaked);
        emit Staked(msg.sender, block.timestamp);
    }

    function harvest(uint256 epochId) external nonReentrant {
        UserStake storage u = stakes[msg.sender];
        require(u.active, "No stake");
        Epoch storage ep = epochs[epochId];
        require(block.timestamp >= ep.endTime, "Epoch not ended");
        // Reward = stake * boost / totalStaked * rewardPool / 10000 (all plaintext divisors)
        euint64 baseReward = FHE.div(FHE.mul(u.stakedAmount, ep.totalRewardPool), 1_000_000);
        euint64 boostedReward = FHE.div(FHE.mul(baseReward, u.boostMultiplierBps), 10000);
        u.pendingRewards = FHE.add(u.pendingRewards, boostedReward);
        u.lastClaimEpoch = epochId;
        FHE.allowThis(u.pendingRewards); FHE.allow(u.pendingRewards, msg.sender);
        emit Harvested(msg.sender, epochId);
    }

    function unstake() external nonReentrant {
        UserStake storage u = stakes[msg.sender];
        require(u.active, "No stake");
        _totalStaked = FHE.sub(_totalStaked, u.stakedAmount);
        u.stakedAmount = FHE.asEuint64(0);
        u.active = false;
        FHE.allowThis(u.stakedAmount); FHE.allow(u.stakedAmount, msg.sender);
        FHE.allowThis(_totalStaked);
        emit Unstaked(msg.sender, block.timestamp);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_totalProtocolRewards, viewer); FHE.allow(_totalStaked, viewer);
    }
    function getStake(address user) external view returns (euint64) { return stakes[user].stakedAmount; }
    function getPendingRewards(address user) external view returns (euint64) { return stakes[user].pendingRewards; }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}