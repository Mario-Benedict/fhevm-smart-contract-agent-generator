// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title DeFiEncryptedGaugeController
/// @notice Gauge weight voting for liquidity incentives. Token holders lock voting
///         power and vote on encrypted gauge weights to direct emissions to pools.
///         Individual voting power is hidden to prevent voting collusion.
contract DeFiEncryptedGaugeController is ZamaEthereumConfig, Ownable {
    struct Gauge {
        string poolName;
        euint32 totalVotingPower;
        euint16 allocatedEmissionBps;
        bool active;
    }

    struct Voter {
        euint64 lockedTokens;
        mapping(uint256 => euint32) votesForGauge;
        mapping(uint256 => bool) hasVoted;
        uint256 lockExpiry;
    }

    mapping(uint256 => Gauge) private gauges;
    uint256 public gaugeCount;
    mapping(address => Voter) private voters;
    address[] public voterList;
    euint64 private _totalLockedTokens;
    euint64 private _totalEmissions;
    uint256 public epochDuration;
    uint256 public currentEpoch;
    uint256 public epochStart;

    event GaugeAdded(uint256 indexed id, string poolName);
    event VoteLocked(address indexed voter, uint256 lockExpiry);
    event VoteCast(address indexed voter, uint256 gaugeId);
    event EmissionsAllocated(uint256 epoch);

    constructor(uint256 _epochDuration) Ownable(msg.sender) {
        epochDuration = _epochDuration;
        currentEpoch = 1;
        epochStart = block.timestamp;
        _totalLockedTokens = FHE.asEuint64(0);
        _totalEmissions = FHE.asEuint64(0);
        FHE.allowThis(_totalLockedTokens);
        FHE.allowThis(_totalEmissions);
    }

    function addGauge(string calldata poolName) external onlyOwner returns (uint256 id) {
        id = gaugeCount++;
        gauges[id].poolName = poolName;
        gauges[id].totalVotingPower = FHE.asEuint32(0);
        gauges[id].allocatedEmissionBps = FHE.asEuint16(0);
        gauges[id].active = true;
        FHE.allowThis(gauges[id].totalVotingPower);
        FHE.allowThis(gauges[id].allocatedEmissionBps);
        emit GaugeAdded(id, poolName);
    }

    function lockAndVote(
        externalEuint64 encTokens, bytes calldata tProof,
        uint256 lockDays
    ) external {
        euint64 tokens = FHE.fromExternal(encTokens, tProof);
        voters[msg.sender].lockedTokens = FHE.add(voters[msg.sender].lockedTokens, tokens);
        voters[msg.sender].lockExpiry = block.timestamp + lockDays * 1 days;
        _totalLockedTokens = FHE.add(_totalLockedTokens, tokens);
        FHE.allowThis(voters[msg.sender].lockedTokens);
        FHE.allow(voters[msg.sender].lockedTokens, msg.sender);
        FHE.allowThis(_totalLockedTokens);
        voterList.push(msg.sender);
        emit VoteLocked(msg.sender, voters[msg.sender].lockExpiry);
    }

    function voteForGauge(
        uint256 gaugeId,
        externalEuint32 encVotePower, bytes calldata proof
    ) external {
        require(gaugeId < gaugeCount && gauges[gaugeId].active, "Invalid gauge");
        require(voters[msg.sender].lockExpiry > block.timestamp, "Lock expired");
        require(!voters[msg.sender].hasVoted[gaugeId], "Already voted this gauge");
        voters[msg.sender].hasVoted[gaugeId] = true;
        euint32 power = FHE.fromExternal(encVotePower, proof);
        voters[msg.sender].votesForGauge[gaugeId] = power;
        gauges[gaugeId].totalVotingPower = FHE.add(gauges[gaugeId].totalVotingPower, power);
        FHE.allowThis(gauges[gaugeId].totalVotingPower);
        emit VoteCast(msg.sender, gaugeId);
    }

    function processEpoch(externalEuint64 encTotalEmissions, bytes calldata proof) external onlyOwner {
        require(block.timestamp >= epochStart + epochDuration, "Epoch not over");
        euint64 emissions = FHE.fromExternal(encTotalEmissions, proof);
        _totalEmissions = FHE.add(_totalEmissions, emissions);
        // Allocate emissions proportionally (simplified)
        for (uint256 i = 0; i < gaugeCount; i++) {
            if (!gauges[i].active) continue;
            // Allocation = emissions / gaugeCount (simplified equal distribution)
            euint16 alloc = FHE.asEuint16(uint16(10000 / gaugeCount));
            gauges[i].allocatedEmissionBps = alloc;
            FHE.allowThis(gauges[i].allocatedEmissionBps);
        }
        // Reset for next epoch
        for (uint256 i = 0; i < gaugeCount; i++) {
            gauges[i].totalVotingPower = FHE.asEuint32(0);
            FHE.allowThis(gauges[i].totalVotingPower);
        }
        currentEpoch++;
        epochStart = block.timestamp;
        FHE.allowThis(_totalEmissions);
        emit EmissionsAllocated(currentEpoch - 1);
    }

    function allowGaugeData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(gauges[id].totalVotingPower, viewer);
        FHE.allow(gauges[id].allocatedEmissionBps, viewer);
    }
}
