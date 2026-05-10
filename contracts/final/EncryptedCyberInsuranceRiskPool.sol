// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCyberInsuranceRiskPool
/// @notice Cyber insurance risk pool: encrypted breach loss estimates, encrypted cybersecurity scores,
///         encrypted ransomware exposure, and confidential threat intelligence sharing.
contract EncryptedCyberInsuranceRiskPool is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum CyberThreat { RANSOMWARE, DATA_BREACH, DDoS, PHISHING, INSIDER_THREAT, SUPPLY_CHAIN }
    enum IndustryVertical { HEALTHCARE, FINANCE, RETAIL, MANUFACTURING, GOVERNMENT, ENERGY }

    struct CyberPolicy {
        address insured;
        IndustryVertical vertical;
        euint64 premiumUSD;              // encrypted annual premium
        euint64 coverageLimitUSD;        // encrypted policy limit
        euint64 deductibleUSD;           // encrypted deductible
        euint64 cyberSecurityScore;      // encrypted security posture score 0-1000
        euint64 revenueUSD;              // encrypted insured revenue
        euint64 dataRecordsCount;        // encrypted sensitive records
        euint64 riskScoreBps;            // encrypted composite risk
        bool active;
        uint256 policyStart;
        uint256 policyEnd;
    }

    struct CyberClaim {
        uint256 policyId;
        CyberThreat threat;
        euint64 estimatedLossUSD;        // encrypted total loss estimate
        euint64 businessInterruptionUSD; // encrypted BI component
        euint64 forensicsCostUSD;        // encrypted forensics cost
        euint64 notificationCostUSD;     // encrypted breach notification cost
        euint64 approvedPayoutUSD;       // encrypted approved payout
        uint256 incidentDate;
        bool reported;
        bool paid;
    }

    struct ThreatIntelligence {
        CyberThreat threat;
        string threatActor;         // anonymized threat actor descriptor
        euint64 industryImpactScore;// encrypted industry impact 0-1000
        euint64 frequencyBps;       // encrypted annual frequency per 1000 companies
        uint256 reportDate;
        bool classified;
    }

    mapping(uint256 => CyberPolicy) private policies;
    mapping(uint256 => CyberClaim[]) private claims;
    mapping(uint256 => ThreatIntelligence) private threatIntel;
    uint256 public policyCount;
    uint256 public threatCount;
    euint64 private _totalPremiumPool;
    euint64 private _totalClaimReserve;
    mapping(address => bool) public isUnderwriter;
    mapping(address => bool) public isThreatAnalyst;
    mapping(address => bool) public isClaimsAdjuster;

    event PolicyIssued(uint256 indexed id, address insured, IndustryVertical vertical);
    event ClaimReported(uint256 indexed policyId, uint256 claimIdx, CyberThreat threat);
    event ClaimPaid(uint256 indexed policyId, uint256 claimIdx);
    event ThreatIntelAdded(uint256 indexed id, CyberThreat threat);
    event SecurityScoreUpdated(uint256 indexed policyId);

    constructor() Ownable(msg.sender) {
        _totalPremiumPool = FHE.asEuint64(0);
        _totalClaimReserve = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumPool);
        FHE.allowThis(_totalClaimReserve);
        isUnderwriter[msg.sender] = true;
        isThreatAnalyst[msg.sender] = true;
        isClaimsAdjuster[msg.sender] = true;
    }

    function addUnderwriter(address u) external onlyOwner { isUnderwriter[u] = true; }
    function addAnalyst(address a) external onlyOwner { isThreatAnalyst[a] = true; }
    function addAdjuster(address a) external onlyOwner { isClaimsAdjuster[a] = true; }

    function issuePolicy(
        address insured, IndustryVertical vertical,
        externalEuint64 encPremium, bytes calldata pProof,
        externalEuint64 encLimit, bytes calldata lProof,
        externalEuint64 encDeductible, bytes calldata dProof,
        externalEuint64 encSecScore, bytes calldata ssProof,
        externalEuint64 encRevenue, bytes calldata rProof,
        externalEuint64 encDataRecords, bytes calldata drProof,
        uint256 duration
    ) external returns (uint256 id) {
        require(isUnderwriter[msg.sender], "Not underwriter");
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        euint64 limit = FHE.fromExternal(encLimit, lProof);
        euint64 deductible = FHE.fromExternal(encDeductible, dProof);
        euint64 secScore = FHE.fromExternal(encSecScore, ssProof);
        euint64 revenue = FHE.fromExternal(encRevenue, rProof);
        euint64 dataRecords = FHE.fromExternal(encDataRecords, drProof);
        // Risk score = (1000 - secScore) * 0.6 + records factor
        ebool _safeSub205 = FHE.ge(FHE.asEuint64(1000), secScore);
        euint64 risk = FHE.div(FHE.mul(FHE.select(_safeSub205, FHE.sub(FHE.asEuint64(1000), secScore), FHE.asEuint64(0)), 6), 10);
        id = policyCount++;
        CyberPolicy storage _s0 = policies[id];
        _s0.insured = insured;
        _s0.vertical = vertical;
        _s0.premiumUSD = premium;
        _s0.coverageLimitUSD = limit;
        _s0.deductibleUSD = deductible;
        _s0.cyberSecurityScore = secScore;
        _s0.revenueUSD = revenue;
        _s0.dataRecordsCount = dataRecords;
        _s0.riskScoreBps = risk;
        _s0.active = true;
        _s0.policyStart = block.timestamp;
        _s0.policyEnd = block.timestamp + duration;
        _totalPremiumPool = FHE.add(_totalPremiumPool, premium);
        // Reserve 40% for claims
        euint64 reserve = FHE.div(FHE.mul(premium, 4000), 10000);
        _totalClaimReserve = FHE.add(_totalClaimReserve, reserve);
        FHE.allowThis(policies[id].premiumUSD);
        FHE.allowThis(policies[id].coverageLimitUSD);
        FHE.allowThis(policies[id].deductibleUSD);
        FHE.allowThis(policies[id].cyberSecurityScore);
        FHE.allowThis(policies[id].revenueUSD);
        FHE.allowThis(policies[id].dataRecordsCount);
        FHE.allowThis(policies[id].riskScoreBps);
        FHE.allow(policies[id].premiumUSD, insured);
        FHE.allow(policies[id].coverageLimitUSD, insured);
        FHE.allow(policies[id].riskScoreBps, msg.sender);
        FHE.allowThis(_totalPremiumPool);
        FHE.allowThis(_totalClaimReserve);
        emit PolicyIssued(id, insured, vertical);
    }

    function reportClaim(
        uint256 policyId, CyberThreat threat,
        externalEuint64 encLoss, bytes calldata lProof,
        externalEuint64 encBI, bytes calldata biProof,
        externalEuint64 encForensics, bytes calldata fProof,
        externalEuint64 encNotification, bytes calldata nProof
    ) external returns (uint256 claimIdx) {
        CyberPolicy storage pol = policies[policyId];
        require(pol.insured == msg.sender && pol.active, "Not insured");
        euint64 loss = FHE.fromExternal(encLoss, lProof);
        euint64 bi = FHE.fromExternal(encBI, biProof);
        euint64 forensics = FHE.fromExternal(encForensics, fProof);
        euint64 notification = FHE.fromExternal(encNotification, nProof);
        euint64 totalLoss = FHE.add(FHE.add(loss, bi), FHE.add(forensics, notification));
        claimIdx = claims[policyId].length;
        claims[policyId].push(CyberClaim({
            policyId: policyId, threat: threat, estimatedLossUSD: totalLoss,
            businessInterruptionUSD: bi, forensicsCostUSD: forensics,
            notificationCostUSD: notification, approvedPayoutUSD: FHE.asEuint64(0),
            incidentDate: block.timestamp, reported: true, paid: false
        }));
        FHE.allowThis(claims[policyId][claimIdx].estimatedLossUSD);
        FHE.allowThis(claims[policyId][claimIdx].businessInterruptionUSD);
        FHE.allowThis(claims[policyId][claimIdx].forensicsCostUSD);
        FHE.allowThis(claims[policyId][claimIdx].approvedPayoutUSD);
        FHE.allow(claims[policyId][claimIdx].estimatedLossUSD, msg.sender);
        emit ClaimReported(policyId, claimIdx, threat);
    }

    function adjudicateClaim(uint256 policyId, uint256 claimIdx, externalEuint64 encApproved, bytes calldata proof) external {
        require(isClaimsAdjuster[msg.sender], "Not adjuster");
        CyberClaim storage cl = claims[policyId][claimIdx];
        require(cl.reported && !cl.paid, "Not eligible");
        euint64 approved = FHE.fromExternal(encApproved, proof);
        // Cap at coverage limit minus deductible
        CyberPolicy storage pol = policies[policyId];
        ebool _safeSub206 = FHE.ge(pol.coverageLimitUSD, pol.deductibleUSD);
        euint64 maxPayout = FHE.select(_safeSub206, FHE.sub(pol.coverageLimitUSD, pol.deductibleUSD), FHE.asEuint64(0));
        ebool withinLimit = FHE.le(approved, maxPayout);
        cl.approvedPayoutUSD = FHE.select(withinLimit, approved, maxPayout);
        cl.paid = true;
        ebool _safeSub207 = FHE.ge(_totalClaimReserve, cl.approvedPayoutUSD);
        _totalClaimReserve = FHE.select(_safeSub207, FHE.sub(_totalClaimReserve, cl.approvedPayoutUSD), FHE.asEuint64(0));
        FHE.allowThis(cl.approvedPayoutUSD);
        FHE.allow(cl.approvedPayoutUSD, pol.insured);
        FHE.allowThis(_totalClaimReserve);
        emit ClaimPaid(policyId, claimIdx);
    }

    function updateSecurityScore(uint256 policyId, externalEuint64 encScore, bytes calldata proof) external {
        require(isUnderwriter[msg.sender], "Not underwriter");
        policies[policyId].cyberSecurityScore = FHE.fromExternal(encScore, proof);
        // Recalculate risk
        euint64 secScore = policies[policyId].cyberSecurityScore;
        ebool _safeSub208 = FHE.ge(FHE.asEuint64(1000), secScore);
        policies[policyId].riskScoreBps = FHE.div(FHE.mul(FHE.select(_safeSub208, FHE.sub(FHE.asEuint64(1000), secScore), FHE.asEuint64(0)), 6), 10);
        FHE.allowThis(policies[policyId].cyberSecurityScore);
        FHE.allowThis(policies[policyId].riskScoreBps);
        emit SecurityScoreUpdated(policyId);
    }

    function addThreatIntelligence(
        CyberThreat threat, string calldata actor,
        externalEuint64 encImpact, bytes calldata iProof,
        externalEuint64 encFrequency, bytes calldata fProof
    ) external returns (uint256 id) {
        require(isThreatAnalyst[msg.sender], "Not analyst");
        euint64 impact = FHE.fromExternal(encImpact, iProof);
        euint64 frequency = FHE.fromExternal(encFrequency, fProof);
        id = threatCount++;
        threatIntel[id] = ThreatIntelligence({
            threat: threat, threatActor: actor,
            industryImpactScore: impact, frequencyBps: frequency,
            reportDate: block.timestamp, classified: true
        });
        FHE.allowThis(threatIntel[id].industryImpactScore);
        FHE.allowThis(threatIntel[id].frequencyBps);
        emit ThreatIntelAdded(id, threat);
    }
}
