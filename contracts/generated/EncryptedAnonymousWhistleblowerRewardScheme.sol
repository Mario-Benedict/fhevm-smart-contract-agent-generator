// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedAnonymousWhistleblowerRewardScheme
/// @notice Confidential bounty scheme for corporate whistleblowers.
///         Report amounts, submission quality scores, and reward pools
///         remain encrypted to protect whistleblower identity and incentivize reporting.
contract EncryptedAnonymousWhistleblowerRewardScheme is
    ZamaEthereumConfig,
    Ownable,
    ReentrancyGuard
{
    struct Report {
        euint64 potentialRecovery; // estimated illegal gains (encrypted)
        euint32 credibilityScore; // reviewer's confidence score
        euint32 completenessScore; // how complete the evidence is
        euint64 rewardEntitlement; // calculated reward
        address reporter; // could be address(0) for _anonymous
        bool _anonymous;
        bool reviewed;
        bool rewarded;
        uint256 submittedAt;
        string categoryHash; // IPFS hash of encrypted category
    }

    mapping(bytes32 => Report) private reports;
    mapping(address => bytes32[]) private reporterReports;
    bytes32[] public reportList;

    euint64 private _rewardPool;
    euint64 private _totalRecoveryEnabled;
    euint64 private _totalRewardsDistributed;
    euint32 private _rewardRateBps; // % of recovery as reward
    euint32 private _minCredibilityScore; // minimum score to qualify

    event ReportSubmitted(bytes32 indexed reportId);
    event ReportReviewed(bytes32 indexed reportId);
    event RewardDistributed(bytes32 indexed reportId);
    event PoolFunded(uint256 amount);

    constructor(
        externalEuint64 encInitPool,
        bytes memory poolProof,
        externalEuint32 encRate,
        bytes memory rateProof,
        externalEuint32 encMinScore,
        bytes memory scoreProof
    ) Ownable(msg.sender) {
        _rewardPool = FHE.fromExternal(encInitPool, poolProof);
        _rewardRateBps = FHE.fromExternal(encRate, rateProof);
        _minCredibilityScore = FHE.fromExternal(encMinScore, scoreProof);
        _totalRecoveryEnabled = FHE.asEuint64(0);
        _totalRewardsDistributed = FHE.asEuint64(0);
        FHE.allowThis(_rewardPool);
        FHE.allowThis(_rewardRateBps);
        FHE.allowThis(_minCredibilityScore);
        FHE.allowThis(_totalRecoveryEnabled);
        FHE.allowThis(_totalRewardsDistributed);
    }

    function fundPool(
        externalEuint64 encAmount,
        bytes calldata proof
    ) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _rewardPool = FHE.add(_rewardPool, amount);
        FHE.allowThis(_rewardPool);
    }

    function submitReport(
        externalEuint64 encRecovery,
        bytes calldata recovProof,
        bool _anonymous,
        string calldata categoryHash
    ) external nonReentrant returns (bytes32 reportId) {
        reportId = keccak256(
            abi.encodePacked(
                _anonymous ? address(0) : msg.sender,
                block.timestamp,
                reportList.length
            )
        );
        Report storage r = reports[reportId];
        r.potentialRecovery = FHE.fromExternal(encRecovery, recovProof);
        r.credibilityScore = FHE.asEuint32(0);
        r.completenessScore = FHE.asEuint32(0);
        r.rewardEntitlement = FHE.asEuint64(0);
        r.reporter = _anonymous ? address(0) : msg.sender;
        r._anonymous = _anonymous;
        r.submittedAt = block.timestamp;
        r.categoryHash = categoryHash;
        FHE.allowThis(r.potentialRecovery);
        FHE.allow(r.potentialRecovery, owner());
        FHE.allowThis(r.credibilityScore);
        FHE.allowThis(r.completenessScore);
        FHE.allowThis(r.rewardEntitlement);
        reportList.push(reportId);
        if (!_anonymous) {
            reporterReports[msg.sender].push(reportId);
        }
        emit ReportSubmitted(reportId);
    }

    function reviewReport(
        bytes32 reportId,
        externalEuint32 encCredibility,
        bytes calldata credProof,
        externalEuint32 encCompleteness,
        bytes calldata compProof
    ) external onlyOwner {
        Report storage r = reports[reportId];
        require(!r.reviewed, "Already reviewed");
        r.credibilityScore = FHE.fromExternal(encCredibility, credProof);
        r.completenessScore = FHE.fromExternal(encCompleteness, compProof);
        // Reward = recovery * rate / 10000 if credibility >= min
        ebool qualifies = FHE.ge(r.credibilityScore, _minCredibilityScore);
        euint64 baseReward = FHE.div(r.potentialRecovery, 10); // 10% reward placeholder
        r.rewardEntitlement = FHE.select(
            qualifies,
            baseReward,
            FHE.asEuint64(0)
        );
        r.reviewed = true;
        FHE.allowThis(r.credibilityScore);
        FHE.allowThis(r.completenessScore);
        FHE.allowThis(r.rewardEntitlement);
        if (!r._anonymous) {
            FHE.allow(r.credibilityScore, r.reporter);
            FHE.allow(r.rewardEntitlement, r.reporter);
        }
        emit ReportReviewed(reportId);
    }

    function distributeReward(
        bytes32 reportId,
        address recipientAddress
    ) external onlyOwner nonReentrant {
        Report storage r = reports[reportId];
        require(r.reviewed && !r.rewarded, "Not eligible");
        ebool poolSufficient = FHE.ge(_rewardPool, r.rewardEntitlement);
        euint64 payment = FHE.select(
            poolSufficient,
            r.rewardEntitlement,
            _rewardPool
        );
        _rewardPool = FHE.sub(_rewardPool, payment);
        _totalRewardsDistributed = FHE.add(_totalRewardsDistributed, payment);
        _totalRecoveryEnabled = FHE.add(
            _totalRecoveryEnabled,
            r.potentialRecovery
        );
        r.rewarded = true;
        FHE.allowThis(_rewardPool);
        FHE.allowThis(_totalRewardsDistributed);
        FHE.allowThis(_totalRecoveryEnabled);
        FHE.allow(payment, recipientAddress);
        emit RewardDistributed(reportId);
    }

    function allowMyReports(bytes32 reportId, address viewer) external {
        require(reports[reportId].reporter == msg.sender, "Not your report");
        FHE.allow(reports[reportId].rewardEntitlement, viewer);
        FHE.allow(reports[reportId].credibilityScore, viewer);
    }

    function allowSchemeMetrics(address viewer) external onlyOwner {
        FHE.allow(_rewardPool, viewer);
        FHE.allow(_totalRewardsDistributed, viewer);
        FHE.allow(_totalRecoveryEnabled, viewer);
    }
}
