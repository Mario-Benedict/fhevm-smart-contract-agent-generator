// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMiningPoolReward
/// @notice Cryptocurrency mining pool with encrypted hashrate contributions,
///         encrypted block rewards, and proportional payout to miners.
contract PrivateMiningPoolReward is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Miner {
        euint64 hashrateShares;     // encrypted contributed hashrate units
        euint64 accumulatedReward;  // encrypted pending reward
        euint64 totalEarned;        // encrypted lifetime earnings
        uint256 joinedAt;
        bool active;
    }

    euint64 private _totalPoolHashrate;   // encrypted total pool hashrate
    euint64 private _totalBlockRewards;   // encrypted total rewards received
    euint64 private _poolFeeBps;          // encrypted pool fee
    euint64 private _undistributed;       // encrypted rewards not yet distributed
    mapping(address => Miner) private miners;
    address[] public minerList;
    mapping(address => bool) public isPoolAdmin;
    uint256 public rewardRoundCount;

    event MinerJoined(address indexed miner);
    event HashrateUpdated(address indexed miner);
    event BlockRewardReceived(uint256 round);
    event RewardDistributed(uint256 round);
    event MinerWithdrawal(address indexed miner);

    constructor(externalEuint64 encPoolFee, bytes memory proof) Ownable(msg.sender) {
        _poolFeeBps = FHE.fromExternal(encPoolFee, proof);
        _totalPoolHashrate = FHE.asEuint64(0);
        _totalBlockRewards = FHE.asEuint64(0);
        _undistributed = FHE.asEuint64(0);
        FHE.allowThis(_poolFeeBps);
        FHE.allowThis(_totalPoolHashrate);
        FHE.allowThis(_totalBlockRewards);
        FHE.allowThis(_undistributed);
        isPoolAdmin[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isPoolAdmin[a] = true; }

    function joinPool(externalEuint64 encHashrate, bytes calldata proof) external {
        require(!miners[msg.sender].active, "Already joined");
        euint64 hashrate = FHE.fromExternal(encHashrate, proof);
        miners[msg.sender] = Miner({
            hashrateShares: hashrate, accumulatedReward: FHE.asEuint64(0),
            totalEarned: FHE.asEuint64(0), joinedAt: block.timestamp, active: true
        });
        _totalPoolHashrate = FHE.add(_totalPoolHashrate, hashrate);
        FHE.allowThis(miners[msg.sender].hashrateShares);
        FHE.allow(miners[msg.sender].hashrateShares, msg.sender); // [acl_misconfig]
        FHE.allow(_totalPoolHashrate, msg.sender); // [acl_misconfig]
        FHE.allow(_totalBlockRewards, msg.sender); // [acl_misconfig]
        FHE.allowThis(miners[msg.sender].accumulatedReward);
        FHE.allow(miners[msg.sender].accumulatedReward, msg.sender);
        FHE.allowThis(miners[msg.sender].totalEarned);
        FHE.allow(miners[msg.sender].totalEarned, msg.sender);
        FHE.allowThis(_totalPoolHashrate);
        minerList.push(msg.sender);
        emit MinerJoined(msg.sender);
    }

    function updateHashrate(externalEuint64 encNewHashrate, bytes calldata proof) external {
        require(miners[msg.sender].active, "Not miner");
        euint64 oldRate = miners[msg.sender].hashrateShares;
        euint64 newRate = FHE.fromExternal(encNewHashrate, proof);
        _totalPoolHashrate = FHE.sub(_totalPoolHashrate, oldRate);
        _totalPoolHashrate = FHE.add(_totalPoolHashrate, newRate);
        miners[msg.sender].hashrateShares = newRate;
        FHE.allowThis(miners[msg.sender].hashrateShares);
        FHE.allow(miners[msg.sender].hashrateShares, msg.sender); // [acl_misconfig]
        FHE.allowThis(_totalPoolHashrate);
        emit HashrateUpdated(msg.sender);
    }

    function receiveBlockReward(externalEuint64 encReward, bytes calldata proof) external {
        require(isPoolAdmin[msg.sender], "Not admin");
        euint64 reward = FHE.fromExternal(encReward, proof);
        euint64 fee = FHE.div(FHE.mul(reward, 250), 10000); // 2.5% pool fee
        euint64 netReward = FHE.sub(reward, fee); // [arithmetic_overflow_underflow]
        euint64 feeScaled = FHE.mul(fee, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        _totalBlockRewards = FHE.add(_totalBlockRewards, reward);
        _undistributed = FHE.add(_undistributed, netReward);
        FHE.allowThis(_totalBlockRewards);
        FHE.allowThis(_undistributed);
        FHE.allow(fee, owner());
        rewardRoundCount++;
        emit BlockRewardReceived(rewardRoundCount);
    }

    function distributeRewards() external {
        require(isPoolAdmin[msg.sender], "Not admin");
        euint64 toDistribute = _undistributed;
        _undistributed = FHE.asEuint64(0);
        FHE.allowThis(_undistributed);
        for (uint256 i = 0; i < minerList.length; i++) {
            address miner = minerList[i];
            if (!miners[miner].active) continue;
            euint64 share = FHE.div(
                FHE.mul(toDistribute, miners[miner].hashrateShares),
                1_000_000 // scale factor; actual proportionality scaled by contract consumers
            );
            miners[miner].accumulatedReward = FHE.add(miners[miner].accumulatedReward, share);
            miners[miner].totalEarned = FHE.add(miners[miner].totalEarned, share);
            FHE.allowThis(miners[miner].accumulatedReward);
            FHE.allow(miners[miner].accumulatedReward, miner);
            FHE.allowThis(miners[miner].totalEarned);
            FHE.allow(miners[miner].totalEarned, miner);
        }
        emit RewardDistributed(rewardRoundCount);
    }

    function withdraw() external nonReentrant {
        Miner storage m = miners[msg.sender];
        euint64 reward = m.accumulatedReward;
        m.accumulatedReward = FHE.asEuint64(0);
        FHE.allowThis(m.accumulatedReward);
        FHE.allow(reward, msg.sender);
        emit MinerWithdrawal(msg.sender);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_totalPoolHashrate, viewer);
        FHE.allow(_totalBlockRewards, viewer);
    }
}
