// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedParametricFloodInsurance
/// @notice Flood insurance triggered by oracle-reported water level readings.
///         Policy premium amounts and payout triggers remain encrypted to
///         prevent competitors from reverse-engineering risk pricing models.
contract EncryptedParametricFloodInsurance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct FloodPolicy {
        euint32 premium;          // monthly premium in USD cents
        euint64 coverageAmount;   // payout if trigger breached
        euint32 triggerLevelCm;   // water level in cm that triggers payout
        euint32 waitingPeriodDays;
        uint256 startDate;
        uint256 endDate;
        bool active;
        bool claimed;
    }

    mapping(address => FloodPolicy) private policies;
    address[] public policyholders;
    address public weatherOracle;

    euint32 private _currentWaterLevelCm;   // encrypted oracle reading
    euint64 private _riskPoolBalance;
    euint64 private _totalExposure;
    euint32 private _poolMinReserveBps;      // min reserve ratio (bps)

    event PolicyIssued(address indexed holder);
    event PolicyRenewed(address indexed holder);
    event ClaimTriggered(address indexed holder);
    event WaterLevelUpdated();
    event PoolFunded(uint256 amount);

    constructor(address oracle, externalEuint32 encReserve, bytes memory reserveProof) Ownable(msg.sender) {
        weatherOracle = oracle;
        _poolMinReserveBps = FHE.fromExternal(encReserve, reserveProof);
        _riskPoolBalance = FHE.asEuint64(0);
        _totalExposure = FHE.asEuint64(0);
        _currentWaterLevelCm = FHE.asEuint32(0);
        FHE.allowThis(_poolMinReserveBps);
        FHE.allowThis(_riskPoolBalance);
        FHE.allowThis(_totalExposure);
        FHE.allowThis(_currentWaterLevelCm);
    }

    function fundPool(externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _riskPoolBalance = FHE.add(_riskPoolBalance, amount);
        FHE.allowThis(_riskPoolBalance);
    }

    function issuePolicy(
        address holder,
        externalEuint32 encPremium, bytes calldata premProof,
        externalEuint64 encCoverage, bytes calldata covProof,
        externalEuint32 encTrigger, bytes calldata trigProof,
        externalEuint32 encWaiting, bytes calldata waitProof,
        uint256 durationDays
    ) external onlyOwner {
        require(!policies[holder].active, "Policy active");
        FloodPolicy storage p = policies[holder];
        p.premium = FHE.fromExternal(encPremium, premProof);
        p.coverageAmount = FHE.fromExternal(encCoverage, covProof);
        p.triggerLevelCm = FHE.fromExternal(encTrigger, trigProof);
        p.waitingPeriodDays = FHE.fromExternal(encWaiting, waitProof);
        p.startDate = block.timestamp;
        p.endDate = block.timestamp + (durationDays * 1 days);
        p.active = true;
        p.claimed = false;
        _totalExposure = FHE.add(_totalExposure, p.coverageAmount);
        FHE.allowThis(p.premium);
        FHE.allow(p.premium, holder);
        FHE.allowThis(p.coverageAmount);
        FHE.allow(p.coverageAmount, holder);
        FHE.allowThis(p.triggerLevelCm);
        FHE.allow(p.triggerLevelCm, holder);
        FHE.allowThis(p.waitingPeriodDays);
        FHE.allowThis(_totalExposure);
        policyholders.push(holder);
        emit PolicyIssued(holder);
    }

    function updateWaterLevel(externalEuint32 encLevel, bytes calldata proof) external {
        require(msg.sender == weatherOracle || msg.sender == owner(), "Not oracle");
        _currentWaterLevelCm = FHE.fromExternal(encLevel, proof);
        FHE.allowThis(_currentWaterLevelCm);
        emit WaterLevelUpdated();
    }

    function triggerClaim(address holder) external nonReentrant {
        FloodPolicy storage p = policies[holder];
        require(p.active && !p.claimed, "Not claimable");
        require(block.timestamp <= p.endDate, "Policy expired");
        // Check if current water level exceeds encrypted trigger
        ebool triggered = FHE.ge(_currentWaterLevelCm, p.triggerLevelCm);
        euint64 payout = FHE.select(triggered, p.coverageAmount, FHE.asEuint64(0));
        ebool poolSufficient = FHE.ge(_riskPoolBalance, payout);
        euint64 actualPayout = FHE.select(poolSufficient, payout, _riskPoolBalance);
        _riskPoolBalance = FHE.sub(_riskPoolBalance, actualPayout);
        p.claimed = true;
        p.active = false;
        FHE.allowThis(_riskPoolBalance);
        FHE.allow(actualPayout, holder);
        FHE.allow(triggered, holder);
        emit ClaimTriggered(holder);
    }

    function allowPolicyData(address viewer) external {
        FHE.allow(policies[msg.sender].premium, viewer);
        FHE.allow(policies[msg.sender].coverageAmount, viewer);
        FHE.allow(policies[msg.sender].triggerLevelCm, viewer);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_riskPoolBalance, viewer);
        FHE.allow(_totalExposure, viewer);
    }
}
