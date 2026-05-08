// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateSpaceDebrisInsurance
/// @notice Space debris collision insurance for satellite operators.
///         Encrypted orbital parameters, collision probability scores,
///         and premium/payout values ensure confidential coverage.
contract PrivateSpaceDebrisInsurance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum OrbitClass { LEO, MEO, GEO, SSO, MolniyaOrbit, GraveyardOrbit }
    enum SatelliteStatus { Operational, Degraded, Defunct, Debris, Insured, ClaimFiled }
    enum ClaimStatus { Submitted, Underwriting, Approved, Rejected, Paid }

    struct SatellitePolicy {
        uint256 policyId;
        address operatorAddr;
        string satelliteNoradId;
        OrbitClass orbitClass;
        euint32 altitudeKm;              // encrypted orbital altitude
        euint32 inclinationMilliDeg;     // encrypted inclination * 1000
        euint64 replacementCostUSD;      // encrypted satellite value
        euint32 collisionProbabilityBps; // encrypted annual collision probability
        euint64 annualPremiumUSD;        // encrypted premium
        euint32 debrisTrackCount;        // encrypted number of tracked debris
        euint64 maxPayoutUSD;            // encrypted max claim payout
        SatelliteStatus status;
        uint256 policyStart;
        uint256 policyEnd;
    }

    struct CollisionClaim {
        uint256 policyId;
        string debrisObjectId;
        euint64 estimatedDamageUSD;      // encrypted damage estimate
        euint32 closestApproachMeters;   // encrypted miss distance
        euint32 relativeVelocityMps;     // encrypted approach speed
        ClaimStatus status;
        uint256 filedAt;
        euint64 approvedPayoutUSD;       // encrypted final payout
    }

    mapping(uint256 => SatellitePolicy) private policies;
    mapping(uint256 => CollisionClaim[]) private claims;
    mapping(address => bool) public isSpaceActuary;
    mapping(address => bool) public isOperator;

    uint256 public policyCount;
    euint64 private _totalPremiumsCollected;
    euint64 private _totalClaimsPaid;
    euint64 private _totalInsuredValue;

    event PolicyIssued(uint256 indexed policyId, string noradId, OrbitClass orbitClass);
    event ClaimFiled(uint256 indexed policyId, uint256 claimIndex);
    event ClaimSettled(uint256 indexed policyId, uint256 claimIndex, ClaimStatus status);
    event DebrisAlertIssued(uint256 indexed policyId);

    modifier onlyActuary() {
        require(isSpaceActuary[msg.sender] || msg.sender == owner(), "Not space actuary");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPremiumsCollected = FHE.asEuint64(0);
        _totalClaimsPaid = FHE.asEuint64(0);
        _totalInsuredValue = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumsCollected);
        FHE.allowThis(_totalClaimsPaid);
        FHE.allowThis(_totalInsuredValue);
        isSpaceActuary[msg.sender] = true;
    }

    function addActuary(address a) external onlyOwner { isSpaceActuary[a] = true; }
    function registerOperator(address op) external onlyOwner { isOperator[op] = true; }

    function issuePolicy(
        string calldata noradId,
        OrbitClass orbitClass,
        externalEuint32 encAltitude, bytes calldata altProof,
        externalEuint32 encInclination, bytes calldata inclProof,
        externalEuint64 encReplacementCost, bytes calldata costProof,
        externalEuint32 encCollisionProb, bytes calldata probProof,
        externalEuint64 encPremium, bytes calldata premProof,
        externalEuint64 encMaxPayout, bytes calldata payoutProof,
        uint256 policyDuration
    ) external onlyActuary returns (uint256 policyId) {
        policyId = policyCount++;
        SatellitePolicy storage p = policies[policyId];
        p.policyId = policyId;
        p.operatorAddr = msg.sender;
        p.satelliteNoradId = noradId;
        p.orbitClass = orbitClass;
        p.altitudeKm = FHE.fromExternal(encAltitude, altProof);
        p.inclinationMilliDeg = FHE.fromExternal(encInclination, inclProof);
        p.replacementCostUSD = FHE.fromExternal(encReplacementCost, costProof);
        p.collisionProbabilityBps = FHE.fromExternal(encCollisionProb, probProof);
        p.annualPremiumUSD = FHE.fromExternal(encPremium, premProof);
        p.debrisTrackCount = FHE.asEuint32(0);
        p.maxPayoutUSD = FHE.fromExternal(encMaxPayout, payoutProof);
        p.status = SatelliteStatus.Insured;
        p.policyStart = block.timestamp;
        p.policyEnd = block.timestamp + policyDuration;

        _totalPremiumsCollected = FHE.add(_totalPremiumsCollected, p.annualPremiumUSD);
        _totalInsuredValue = FHE.add(_totalInsuredValue, p.replacementCostUSD);

        FHE.allowThis(p.altitudeKm); FHE.allowThis(p.inclinationMilliDeg);
        FHE.allowThis(p.replacementCostUSD); FHE.allow(p.replacementCostUSD, msg.sender);
        FHE.allowThis(p.collisionProbabilityBps); FHE.allow(p.collisionProbabilityBps, msg.sender);
        FHE.allowThis(p.annualPremiumUSD); FHE.allow(p.annualPremiumUSD, msg.sender);
        FHE.allowThis(p.debrisTrackCount);
        FHE.allowThis(p.maxPayoutUSD); FHE.allow(p.maxPayoutUSD, msg.sender);
        FHE.allowThis(_totalPremiumsCollected); FHE.allowThis(_totalInsuredValue);

        emit PolicyIssued(policyId, noradId, orbitClass);
    }

    function updateDebrisTracking(
        uint256 policyId,
        externalEuint32 encDebrisCount, bytes calldata proof
    ) external onlyActuary {
        euint32 debrisCount = FHE.fromExternal(encDebrisCount, proof);
        policies[policyId].debrisTrackCount = debrisCount;
        FHE.allowThis(policies[policyId].debrisTrackCount);
        // Alert if debris count > 100
        ebool highDebris = FHE.gt(debrisCount, FHE.asEuint32(100));
        if (FHE.isInitialized(highDebris)) emit DebrisAlertIssued(policyId);
    }

    function fileClaim(
        uint256 policyId,
        string calldata debrisObjectId,
        externalEuint64 encDamage, bytes calldata damProof,
        externalEuint32 encApproach, bytes calldata approachProof,
        externalEuint32 encVelocity, bytes calldata velProof
    ) external nonReentrant returns (uint256 claimIdx) {
        SatellitePolicy storage p = policies[policyId];
        require(p.operatorAddr == msg.sender || isOperator[msg.sender], "Not operator");
        require(p.status == SatelliteStatus.Insured, "Not insured");
        require(block.timestamp < p.policyEnd, "Policy expired");

        euint64 damage = FHE.fromExternal(encDamage, damProof);
        euint32 approach = FHE.fromExternal(encApproach, approachProof);
        euint32 velocity = FHE.fromExternal(encVelocity, velProof);

        claimIdx = claims[policyId].length;
        claims[policyId].push(CollisionClaim({
            policyId: policyId,
            debrisObjectId: debrisObjectId,
            estimatedDamageUSD: damage,
            closestApproachMeters: approach,
            relativeVelocityMps: velocity,
            status: ClaimStatus.Submitted,
            filedAt: block.timestamp,
            approvedPayoutUSD: FHE.asEuint64(0)
        }));

        p.status = SatelliteStatus.ClaimFiled;

        FHE.allowThis(claims[policyId][claimIdx].estimatedDamageUSD);
        FHE.allow(claims[policyId][claimIdx].estimatedDamageUSD, msg.sender);
        FHE.allowThis(claims[policyId][claimIdx].closestApproachMeters);
        FHE.allowThis(claims[policyId][claimIdx].relativeVelocityMps);
        FHE.allowThis(claims[policyId][claimIdx].approvedPayoutUSD);

        emit ClaimFiled(policyId, claimIdx);
    }

    function settleClaim(
        uint256 policyId,
        uint256 claimIdx,
        ClaimStatus decision,
        externalEuint64 encPayout, bytes calldata payoutProof
    ) external onlyActuary {
        CollisionClaim storage c = claims[policyId][claimIdx];
        require(c.status == ClaimStatus.Submitted || c.status == ClaimStatus.Underwriting, "Wrong status");
        euint64 payout = FHE.fromExternal(encPayout, payoutProof);
        // Enforce max payout cap
        ebool withinCap = FHE.le(payout, policies[policyId].maxPayoutUSD);
        euint64 actualPayout = FHE.select(withinCap, payout, policies[policyId].maxPayoutUSD);
        c.approvedPayoutUSD = actualPayout;
        c.status = decision;
        if (decision == ClaimStatus.Paid) {
            _totalClaimsPaid = FHE.add(_totalClaimsPaid, actualPayout);
            FHE.allowThis(_totalClaimsPaid);
        }
        FHE.allowThis(c.approvedPayoutUSD);
        FHE.allow(c.approvedPayoutUSD, policies[policyId].operatorAddr);
        emit ClaimSettled(policyId, claimIdx, decision);
    }

    function allowInsuranceStats(address viewer) external onlyOwner {
        FHE.allow(_totalPremiumsCollected, viewer);
        FHE.allow(_totalClaimsPaid, viewer);
        FHE.allow(_totalInsuredValue, viewer);
    }
}
