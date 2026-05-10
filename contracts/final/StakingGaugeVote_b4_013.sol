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
        euint64 amountWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 amountExposure = FHE.sub(amountWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
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