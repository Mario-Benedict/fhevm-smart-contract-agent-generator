// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCyberInsuranceUnderwriting
/// @notice Cyber risk insurance with encrypted vulnerability scores,
///         breach history, and premium calculations. Claims are
///         processed with encrypted incident loss estimates.
contract EncryptedCyberInsuranceUnderwriting is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum IndustryVertical { Healthcare, Finance, Retail, Government, Energy, Technology, Manufacturing }
    enum CyberEventType { DataBreach, Ransomware, DDoS, InsiderThreat, SupplyChainAttack, PhishingFraud }
    enum PolicyStatus { Quoted, Active, Lapsed, Cancelled, ClaimInProgress }

    struct CyberRiskProfile {
        address insured;
        IndustryVertical industry;
        euint32 securityScoreBps;         // encrypted security posture 0-10000
        euint32 annualRevenueMillionUSD;  // encrypted revenue for exposure calc
        euint32 employeeCount;            // encrypted headcount
        euint32 patchingCadenceDays;      // encrypted avg patch lag
        euint32 mfaAdoptionBps;           // encrypted MFA coverage
        euint32 breachCountLast5Yr;       // encrypted historical breaches
        euint32 dataRecordsMillions;      // encrypted sensitive records held
        bool profileComplete;
    }

    struct CyberPolicy {
        uint256 policyId;
        address insured;
        euint64 premiumAnnualUSD;         // encrypted annual premium
        euint64 coverageLimitUSD;         // encrypted policy limit
        euint64 deductibleUSD;            // encrypted deductible
        euint32 retentionBps;             // encrypted self-insured retention
        euint64 totalClaimsPaid;          // encrypted claims paid this policy
        PolicyStatus status;
        uint256 policyStart;
        uint256 policyEnd;
    }

    struct CyberClaim {
        uint256 policyId;
        CyberEventType eventType;
        euint64 grossLossUSD;             // encrypted gross incident loss
        euint64 insuredLossUSD;           // encrypted loss above deductible
        euint64 forensicCostUSD;          // encrypted investigation cost
        euint64 regulatoryFineUSD;        // encrypted regulatory penalties
        euint64 approvedPayoutUSD;        // encrypted approved claim
        bool approved;
        uint256 incidentDate;
        uint256 claimedAt;
    }

    mapping(address => CyberRiskProfile) private riskProfiles;
    mapping(uint256 => CyberPolicy) private policies;
    mapping(uint256 => CyberClaim[]) private claims;
    mapping(address => uint256[]) private insuredPolicies;
    mapping(address => bool) public isUnderwriter;

    uint256 public policyCount;
    euint64 private _totalPremiumsWritten;
    euint64 private _totalClaimsPaid;
    euint64 private _totalExposure;

    event RiskProfileUpdated(address indexed insured);
    event PolicyIssued(uint256 indexed policyId, address insured);
    event ClaimFiled(uint256 indexed policyId, CyberEventType eventType);
    event ClaimSettled(uint256 indexed policyId, uint256 claimIdx);

    modifier onlyUnderwriter() {
        require(isUnderwriter[msg.sender] || msg.sender == owner(), "Not underwriter");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPremiumsWritten = FHE.asEuint64(0);
        _totalClaimsPaid = FHE.asEuint64(0);
        _totalExposure = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumsWritten);
        FHE.allowThis(_totalClaimsPaid);
        FHE.allowThis(_totalExposure);
        isUnderwriter[msg.sender] = true;
    }

    function addUnderwriter(address uw) external onlyOwner { isUnderwriter[uw] = true; }

    function submitRiskProfile(
        IndustryVertical industry,
        externalEuint32 encSecurityScore, bytes calldata secProof,
        externalEuint32 encRevenue, bytes calldata revProof,
        externalEuint32 encEmployees, bytes calldata empProof,
        externalEuint32 encPatchDays, bytes calldata patchProof,
        externalEuint32 encMFA, bytes calldata mfaProof,
        externalEuint32 encBreaches, bytes calldata breachProof,
        externalEuint32 encRecords, bytes calldata recordProof
    ) external {
        CyberRiskProfile storage profile = riskProfiles[msg.sender];
        profile.insured = msg.sender;
        profile.industry = industry;
        profile.securityScoreBps = FHE.fromExternal(encSecurityScore, secProof);
        profile.annualRevenueMillionUSD = FHE.fromExternal(encRevenue, revProof);
        profile.employeeCount = FHE.fromExternal(encEmployees, empProof);
        profile.patchingCadenceDays = FHE.fromExternal(encPatchDays, patchProof);
        profile.mfaAdoptionBps = FHE.fromExternal(encMFA, mfaProof);
        profile.breachCountLast5Yr = FHE.fromExternal(encBreaches, breachProof);
        profile.dataRecordsMillions = FHE.fromExternal(encRecords, recordProof);
        profile.profileComplete = true;
        FHE.allowThis(profile.securityScoreBps); FHE.allow(profile.securityScoreBps, msg.sender);
        FHE.allowThis(profile.annualRevenueMillionUSD); FHE.allow(profile.annualRevenueMillionUSD, msg.sender);
        FHE.allowThis(profile.employeeCount); FHE.allow(profile.employeeCount, msg.sender);
        FHE.allowThis(profile.patchingCadenceDays);
        FHE.allowThis(profile.mfaAdoptionBps);
        FHE.allowThis(profile.breachCountLast5Yr);
        FHE.allowThis(profile.dataRecordsMillions);
        emit RiskProfileUpdated(msg.sender);
    }

    function issuePolicy(
        address insured,
        externalEuint64 encPremium, bytes calldata premProof,
        externalEuint64 encCoverageLimit, bytes calldata coverProof,
        externalEuint64 encDeductible, bytes calldata deducProof,
        externalEuint32 encRetention, bytes calldata retProof,
        uint256 policyDuration
    ) external onlyUnderwriter returns (uint256 policyId) {
        require(riskProfiles[insured].profileComplete, "Risk profile not complete");
        policyId = policyCount++;
        CyberPolicy storage p = policies[policyId];
        p.policyId = policyId;
        p.insured = insured;
        p.premiumAnnualUSD = FHE.fromExternal(encPremium, premProof);
        p.coverageLimitUSD = FHE.fromExternal(encCoverageLimit, coverProof);
        p.deductibleUSD = FHE.fromExternal(encDeductible, deducProof);
        p.retentionBps = FHE.fromExternal(encRetention, retProof);
        p.totalClaimsPaid = FHE.asEuint64(0);
        p.status = PolicyStatus.Active;
        p.policyStart = block.timestamp;
        p.policyEnd = block.timestamp + policyDuration;
        insuredPolicies[insured].push(policyId);
        _totalPremiumsWritten = FHE.add(_totalPremiumsWritten, p.premiumAnnualUSD);
        _totalExposure = FHE.add(_totalExposure, p.coverageLimitUSD);
        FHE.allowThis(p.premiumAnnualUSD); FHE.allow(p.premiumAnnualUSD, insured);
        FHE.allowThis(p.coverageLimitUSD); FHE.allow(p.coverageLimitUSD, insured);
        FHE.allowThis(p.deductibleUSD); FHE.allow(p.deductibleUSD, insured);
        FHE.allowThis(p.retentionBps);
        FHE.allowThis(p.totalClaimsPaid); FHE.allow(p.totalClaimsPaid, insured);
        FHE.allowThis(_totalPremiumsWritten); FHE.allowThis(_totalExposure);
        emit PolicyIssued(policyId, insured);
    }

    function fileClaim(
        uint256 policyId,
        CyberEventType eventType,
        externalEuint64 encGrossLoss, bytes calldata grossProof,
        externalEuint64 encForensicCost, bytes calldata forensicProof,
        externalEuint64 encRegulatoryFine, bytes calldata fineProof,
        uint256 incidentDate
    ) external nonReentrant {
        CyberPolicy storage p = policies[policyId];
        require(p.insured == msg.sender, "Not insured");
        require(p.status == PolicyStatus.Active, "Policy not active");
        require(block.timestamp < p.policyEnd, "Policy expired");

        euint64 grossLoss = FHE.fromExternal(encGrossLoss, grossProof);
        euint64 forensicCost = FHE.fromExternal(encForensicCost, forensicProof);
        euint64 regulatoryFine = FHE.fromExternal(encRegulatoryFine, fineProof);

        // Insured loss = max(0, grossLoss - deductible)
        ebool exceedsDeductible = FHE.gt(grossLoss, p.deductibleUSD);
        euint64 insuredLoss = FHE.select(exceedsDeductible, FHE.sub(grossLoss, p.deductibleUSD), FHE.asEuint64(0));
        // Cap at coverage limit
        ebool withinLimit = FHE.le(insuredLoss, p.coverageLimitUSD);
        euint64 cappedLoss = FHE.select(withinLimit, insuredLoss, p.coverageLimitUSD);

        uint256 claimIdx = claims[policyId].length;
        claims[policyId].push(CyberClaim({
            policyId: policyId,
            eventType: eventType,
            grossLossUSD: grossLoss,
            insuredLossUSD: cappedLoss,
            forensicCostUSD: forensicCost,
            regulatoryFineUSD: regulatoryFine,
            approvedPayoutUSD: FHE.asEuint64(0),
            approved: false,
            incidentDate: incidentDate,
            claimedAt: block.timestamp
        }));

        p.status = PolicyStatus.ClaimInProgress;

        FHE.allowThis(claims[policyId][claimIdx].grossLossUSD);
        FHE.allowThis(claims[policyId][claimIdx].insuredLossUSD); FHE.allow(claims[policyId][claimIdx].insuredLossUSD, msg.sender);
        FHE.allowThis(claims[policyId][claimIdx].forensicCostUSD);
        FHE.allowThis(claims[policyId][claimIdx].regulatoryFineUSD);
        FHE.allowThis(claims[policyId][claimIdx].approvedPayoutUSD);

        emit ClaimFiled(policyId, eventType);
    }

    function settleClaim(
        uint256 policyId,
        uint256 claimIdx,
        bool approved,
        externalEuint64 encPayout, bytes calldata payoutProof
    ) external onlyUnderwriter nonReentrant {
        CyberClaim storage c = claims[policyId][claimIdx];
        require(!c.approved, "Already settled");
        euint64 payout = FHE.fromExternal(encPayout, payoutProof);
        c.approvedPayoutUSD = payout;
        c.approved = approved;
        if (approved) {
            CyberPolicy storage p = policies[policyId];
            p.totalClaimsPaid = FHE.add(p.totalClaimsPaid, payout);
            p.status = PolicyStatus.Active;
            _totalClaimsPaid = FHE.add(_totalClaimsPaid, payout);
            FHE.allowThis(p.totalClaimsPaid);
            FHE.allow(p.totalClaimsPaid, p.insured);
            FHE.allowThis(_totalClaimsPaid);
        }
        FHE.allowThis(c.approvedPayoutUSD);
        FHE.allow(c.approvedPayoutUSD, policies[policyId].insured);
        emit ClaimSettled(policyId, claimIdx);
    }

    function allowPortfolioStats(address viewer) external onlyOwner {
        FHE.allow(_totalPremiumsWritten, viewer);
        FHE.allow(_totalClaimsPaid, viewer);
        FHE.allow(_totalExposure, viewer);
    }

    function allowRiskProfileView(address insured, address viewer) external onlyUnderwriter {
        CyberRiskProfile storage profile = riskProfiles[insured];
        FHE.allow(profile.securityScoreBps, viewer);
        FHE.allow(profile.breachCountLast5Yr, viewer);
        FHE.allow(profile.dataRecordsMillions, viewer);
    }
}
