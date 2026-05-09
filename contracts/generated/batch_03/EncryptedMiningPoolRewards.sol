// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedMiningPoolRewards - Private mining pool with encrypted hashrate contributions and payouts
contract EncryptedMiningPoolRewards is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Miner {
        euint64 hashrateShares;   // contributed hash shares this epoch
        euint64 totalEarned;
        euint64 pendingPayout;
        euint32 blocksContributed;
        bool    registered;
    }

    struct Epoch {
        uint256 startBlock;
        uint256 endBlock;
        euint64 totalReward;
        euint64 totalHashShares;
        bool    finalized;
    }

    mapping(address => Miner)    public miners;
    mapping(uint256 => Epoch)    public epochs;
    mapping(uint256 => mapping(address => euint64)) private epochContributions;
    address[] public minerList;
    uint256 public currentEpoch;
    uint256 public epochDurationBlocks;

    event MinerRegistered(address indexed miner);
    event SharesSubmitted(uint256 indexed epoch, address indexed miner);
    event EpochFinalized(uint256 indexed epoch);
    event RewardClaimed(address indexed miner);

    constructor(uint256 _epochDurationBlocks) Ownable(msg.sender) {
        epochDurationBlocks = _epochDurationBlocks;
        _startNewEpoch();
    }

    function _startNewEpoch() internal {
        epochs[currentEpoch] = Epoch({
            startBlock:    block.number,
            endBlock:      block.number + epochDurationBlocks,
            totalReward:   FHE.asEuint64(0),
            totalHashShares: FHE.asEuint64(0),
            finalized:     false
        });
        FHE.allowThis(epochs[currentEpoch].totalReward);
        FHE.allowThis(epochs[currentEpoch].totalHashShares);
    }

    function registerMiner() external {
        require(!miners[msg.sender].registered, "Already registered");
        Miner storage m = miners[msg.sender];
        m.hashrateShares     = FHE.asEuint64(0);
        m.totalEarned        = FHE.asEuint64(0);
        m.pendingPayout      = FHE.asEuint64(0);
        m.registered         = true;
        FHE.allowThis(m.hashrateShares); FHE.allowThis(m.totalEarned); FHE.allowThis(m.pendingPayout);
        FHE.allow(m.hashrateShares, msg.sender); FHE.allow(m.pendingPayout, msg.sender);
        minerList.push(msg.sender);
        emit MinerRegistered(msg.sender);
    }

    function submitShares(
        uint256 epochId,
        externalEuint64 encShares, bytes calldata inputProof
    ) external {
        require(miners[msg.sender].registered, "Not registered");
        Epoch storage e = epochs[epochId];
        require(!e.finalized && block.number <= e.endBlock, "Epoch closed");
        euint64 shares = FHE.fromExternal(encShares, inputProof);
        epochContributions[epochId][msg.sender] = FHE.add(epochContributions[epochId][msg.sender], shares);
        e.totalHashShares = FHE.add(e.totalHashShares, shares);
        miners[msg.sender].blocksContributed = FHE.add(miners[msg.sender].blocksContributed, FHE.asEuint32(1));
        FHE.allowThis(miners[msg.sender].blocksContributed);
        FHE.allowThis(epochContributions[epochId][msg.sender]);
        FHE.allowThis(e.totalHashShares);
        FHE.allow(epochContributions[epochId][msg.sender], msg.sender);
        emit SharesSubmitted(epochId, msg.sender);
    }

    function addEpochReward(uint256 epochId, externalEuint64 encReward, bytes calldata inputProof)
        external onlyOwner
    {
        euint64 reward = FHE.fromExternal(encReward, inputProof);
        epochs[epochId].totalReward = FHE.add(epochs[epochId].totalReward, reward);
        FHE.allowThis(epochs[epochId].totalReward);
    }

    function finalizeEpoch(uint256 epochId, address[] calldata _minerList, uint64 totalHashSharesPlaintext) external onlyOwner {
        Epoch storage e = epochs[epochId];
        require(!e.finalized && block.number > e.endBlock, "Cannot finalize");
        e.finalized = true;
        for (uint256 i = 0; i < _minerList.length; i++) {
            address miner = _minerList[i];
            euint64 contrib = epochContributions[epochId][miner];
            euint64 share = totalHashSharesPlaintext > 0 ? FHE.div(FHE.mul(contrib, e.totalReward), totalHashSharesPlaintext) : FHE.asEuint64(0);
            miners[miner].pendingPayout = FHE.add(miners[miner].pendingPayout, share);
            miners[miner].totalEarned   = FHE.add(miners[miner].totalEarned,   share);
            FHE.allowThis(miners[miner].pendingPayout); FHE.allowThis(miners[miner].totalEarned);
            FHE.allow(miners[miner].pendingPayout, miner);
        }
        emit EpochFinalized(epochId);
        currentEpoch++;
        _startNewEpoch();
    }

    function claimReward() external nonReentrant {
        require(miners[msg.sender].registered, "Not registered");
        euint64 payout = miners[msg.sender].pendingPayout;
        miners[msg.sender].pendingPayout = FHE.asEuint64(0);
        FHE.allowThis(miners[msg.sender].pendingPayout);
        FHE.allowTransient(payout, msg.sender);
        emit RewardClaimed(msg.sender);
    }
}
