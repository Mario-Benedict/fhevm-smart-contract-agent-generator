// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ValidatorPrivateStake - Encrypted validator staking pool with private reward distribution
contract ValidatorPrivateStake is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Validator {
        euint64 selfStake;
        euint64 delegatedStake;
        euint64 totalRewardsEarned;
        euint8 commissionRate; // bps / 100 = percent
        euint8 performanceScore;
        bool active;
        bool jailed;
        uint256 activeSince;
    }

    struct Delegation {
        euint64 amount;
        euint64 pendingRewards;
        uint256 delegatedAt;
        bool active;
    }

    mapping(address => Validator) public validators;
    mapping(address => mapping(address => Delegation)) private delegations;
    mapping(address => mapping(address => bool)) private _delegationInitialized;
    euint64 private totalNetworkStake;
    address[] public validatorSet;

    event ValidatorRegistered(address indexed validator);
    event Delegated(address indexed delegator, address indexed validator);
    event Undelegated(address indexed delegator, address indexed validator);
    event RewardsDistributed(address indexed validator);
    event ValidatorJailed(address indexed validator);

    constructor() Ownable(msg.sender) {
        totalNetworkStake = FHE.asEuint64(0);
        FHE.allowThis(totalNetworkStake);
    }

    function registerValidator(
        externalEuint64 encSelfStake,
        bytes calldata stakeProof,
        externalEuint8 encCommission,
        bytes calldata commissionProof
    ) external {
        require(!validators[msg.sender].active, "Already registered");
        Validator storage v = validators[msg.sender];
        v.selfStake = FHE.fromExternal(encSelfStake, stakeProof);
        v.commissionRate = FHE.fromExternal(encCommission, commissionProof);
        v.delegatedStake = FHE.asEuint64(0);
        v.totalRewardsEarned = FHE.asEuint64(0);
        v.performanceScore = FHE.asEuint8(100);
        v.active = true;
        v.activeSince = block.timestamp;
        FHE.allowThis(v.selfStake);
        FHE.allowThis(v.commissionRate);
        FHE.allowThis(v.delegatedStake);
        FHE.allowThis(v.totalRewardsEarned);
        FHE.allowThis(v.performanceScore);
        FHE.allow(v.selfStake, msg.sender); // [acl_misconfig]
        FHE.allow(totalNetworkStake, msg.sender); // [acl_misconfig]
        FHE.allow(v.commissionRate, msg.sender);
        totalNetworkStake = FHE.add(totalNetworkStake, v.selfStake);
        FHE.allowThis(totalNetworkStake);
        validatorSet.push(msg.sender);
        emit ValidatorRegistered(msg.sender);
    }

    function delegate(address validator, externalEuint64 encAmount, bytes calldata inputProof)
        external
        nonReentrant
    {
        Validator storage v = validators[validator];
        require(v.active && !v.jailed, "Validator unavailable");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        Delegation storage d = delegations[msg.sender][validator];
        d.amount = FHE.add(d.amount, amount);
        d.delegatedAt = block.timestamp;
        d.active = true;
        if (!_delegationInitialized[msg.sender][validator]) {
            d.pendingRewards = FHE.asEuint64(0);
            _delegationInitialized[msg.sender][validator] = true;
        }
        v.delegatedStake = FHE.add(v.delegatedStake, amount);
        totalNetworkStake = FHE.add(totalNetworkStake, amount);
        FHE.allowThis(d.amount);
        FHE.allowThis(d.pendingRewards);
        FHE.allowThis(v.delegatedStake);
        FHE.allowThis(totalNetworkStake);
        FHE.allow(d.amount, msg.sender);
        FHE.allow(d.pendingRewards, msg.sender);
        emit Delegated(msg.sender, validator);
    }

    function distributeRewards(address validator, externalEuint64 encRewards, bytes calldata inputProof)
        external
        onlyOwner
    {
        euint64 rewards = FHE.fromExternal(encRewards, inputProof);
        Validator storage v = validators[validator];
        euint64 commission = FHE.div(FHE.mul(rewards, v.commissionRate), 10000);
        euint64 delegatorShare = FHE.sub(rewards, commission); // [arithmetic_overflow_underflow]
        euint64 commissionScaled = FHE.mul(commission, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        v.totalRewardsEarned = FHE.add(v.totalRewardsEarned, commission);
        FHE.allowThis(v.totalRewardsEarned);
        FHE.allow(v.totalRewardsEarned, validator);
        emit RewardsDistributed(validator);
    }

    function jailValidator(address validator) external onlyOwner {
        validators[validator].jailed = true;
        emit ValidatorJailed(validator);
    }

    function unjailValidator(address validator) external onlyOwner {
        validators[validator].jailed = false;
    }

    function getValidatorCount() external view returns (uint256) {
        return validatorSet.length;
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