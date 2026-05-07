// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title StakingGaugeVote_b4_013 - Gauge-weighted staking reward distribution
contract StakingGaugeVote_b4_013 is ZamaEthereumConfig {
    address public admin;

    struct Gauge {
        string name;
        euint32 voteWeight;
        euint64 rewardsAllocated;
    }

    Gauge[] public gauges;
    mapping(address => euint32) public voterPower;
    mapping(address => mapping(uint256 => euint32)) private gaugeVotes;
    euint64 private totalRewards;
    euint32 private totalVoteWeight;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
        totalRewards = FHE.asEuint64(0);
        totalVoteWeight = FHE.asEuint32(0);
        FHE.allowThis(totalRewards);
        FHE.allowThis(totalVoteWeight);
    }

    function addGauge(string calldata name) public onlyAdmin {
        gauges.push(Gauge({ name: name, voteWeight: FHE.asEuint32(0), rewardsAllocated: FHE.asEuint64(0) }));
        uint256 idx = gauges.length - 1;
        FHE.allowThis(gauges[idx].voteWeight);
        FHE.allowThis(gauges[idx].rewardsAllocated);
    }

    function setVoterPower(address voter, externalEuint32 powerStr, bytes calldata proof) public onlyAdmin {
        euint32 power = FHE.fromExternal(powerStr, proof);
        voterPower[voter] = power;
        FHE.allowThis(voterPower[voter]);
    }

    function voteForGauge(uint256 gaugeId, externalEuint32 weightStr, bytes calldata proof) public {
        require(gaugeId < gauges.length, "Invalid gauge");
        euint32 weight = FHE.fromExternal(weightStr, proof);
        ebool ok = FHE.le(weight, voterPower[msg.sender]);
        euint32 actual = FHE.select(ok, weight, voterPower[msg.sender]);
        gauges[gaugeId].voteWeight = FHE.add(gauges[gaugeId].voteWeight, actual);
        totalVoteWeight = FHE.add(totalVoteWeight, actual);
        gaugeVotes[msg.sender][gaugeId] = FHE.add(gaugeVotes[msg.sender][gaugeId], actual);
        voterPower[msg.sender] = FHE.sub(voterPower[msg.sender], actual);
        FHE.allowThis(gauges[gaugeId].voteWeight);
        FHE.allowThis(totalVoteWeight);
        FHE.allowThis(voterPower[msg.sender]);
    }

    function depositRewards(externalEuint64 amountStr, bytes calldata proof) public onlyAdmin {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        totalRewards = FHE.add(totalRewards, amount);
        FHE.allowThis(totalRewards);
    }

    function allowGaugeWeight(uint256 gaugeId, address viewer) public onlyAdmin {
        FHE.allow(gauges[gaugeId].voteWeight, viewer);
        FHE.allow(gauges[gaugeId].rewardsAllocated, viewer);
    }

    function getGaugeCount() public view returns (uint256) {
        return gauges.length;
    }
}
