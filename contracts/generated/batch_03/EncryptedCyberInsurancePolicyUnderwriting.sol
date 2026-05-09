// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCyberInsurancePolicyUnderwriting
/// @notice Cyber insurance underwriting with encrypted cybersecurity posture
///         scores, breach history, ransomware vulnerability assessments,
///         premium calculations and confidential claims processing.
contract EncryptedCyberInsurancePolicyUnderwriting is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum CoverageType { FIRST_PARTY_BREACH, THIRD_PARTY_LIABILITY, RANSOMWARE, BEC_FRAUD, REGULATORY_FINES, BUSINESS_INTERRUPTION }
    enum PolicyStatus { QUOTED, BOUND, ACTIVE, LAPSED, CANCELLED, CLAIMED }
    enum IndustryVertical { HEALTHCARE, FINANCE, RETAIL, MANUFACTURING, GOVERNMENT, EDUCATION, ENERGY }

    struct CyberRiskProfile {
        IndustryVertical industry;
        euint64 annualRevenue;              // encrypted annual revenue USD
        euint64 recordsStored;             // encrypted number of PII records
        euint64 cyberMaturityScore;        // encrypted NIST CSF score (0-100)
        euint64 endpointProtectionScore;   // encrypted EDR coverage score
        euint64 mfaAdoptionRate;           // encrypted MFA adoption (0-100)
        euint64 patchingVelocityScore;     // encrypted patching speed score
        euint64 backupRecoveryScore;       // encrypted backup/DR score
        euint64 thirdPartyRiskScore;       // encrypted vendor risk score
        euint64 priorBreachLossAmount;     // encrypted historical breach losses
        euint32 priorBreachCount;          // encrypted breach incident count
        uint256 lastAssessmentDate;
        bool mspManaged;
    }

    struct CyberPolicy {
        address insured;
        PolicyStatus status;
        euint64 annualPremium;             // encrypted annual premium
        euint64 aggregateLimit;            // encrypted per-policy limit
        euint64 retentionAmount;           // encrypted deductible/retention
        euint64 sublimitRansomware;        // encrypted ransomware sublimit
        euint64 sublimitBEC;               // encrypted BEC sublimit
        euint64 sublimitBI;                // encrypted business interruption sublimit
        euint64 retroactivePremiumAdjust;  // encrypted retroactive premium change
        euint64 earnedPremium;             // encrypted earned premium to date
        uint256 inceptionDate;
        uint256 expiryDate;
        bool coInsurance;
        uint8 coInsurancePercent;
    }

    struct Claim {
        bytes32 policyId;
        address insured;
        CoverageType coverageType;
        euint64 claimedAmount;             // encrypted claimed loss
        euint64 reservedAmount;            // encrypted claims reserve
        euint64 paidAmount;               // encrypted amount paid
        euint64 subrogationRecovered;      // encrypted subrogation amount
        euint64 publicRelationsCosts;      // encrypted PR/notification costs
        euint64 forensicsCosts;            // encrypted forensics investigation
        uint256 incidentDate;
        uint256 reportedDate;
        bool litigationInvolved;
        bool regulatoryNotificationRequired;
    }

    mapping(bytes32 => CyberRiskProfile) private riskProfiles;
    mapping(bytes32 => CyberPolicy) private policies;
    mapping(bytes32 => Claim) private claims;
    mapping(address => bytes32) public insuredToPolicy;
    mapping(address => bool) public authorizedUnderwriter;

    euint64 private _totalGrossPremiumWritten;  // encrypted GPW
    euint64 private _totalClaimsReserved;       // encrypted total reserve
    euint64 private _totalClaimsPaid;           // encrypted total paid
    euint64 private _lossRatio;                 // encrypted loss ratio (bps)
    euint64 private _insuranceFundBalance;      // encrypted insurance fund

    event PolicyQuoted(bytes32 indexed policyId, address insured);
    event PolicyBound(bytes32 indexed policyId);
    event ClaimReported(bytes32 indexed claimId, bytes32 indexed policyId, CoverageType coverage);
    event ClaimReserveUpdated(bytes32 indexed claimId);
    event ClaimPaid(bytes32 indexed claimId);
    event RiskProfileUpdated(bytes32 indexed profileId);

    constructor(
        externalEuint64 encInitInsuranceFund, bytes memory iifProof
    ) Ownable(msg.sender) {
        _insuranceFundBalance = FHE.fromExternal(encInitInsuranceFund, iifProof);
        _totalGrossPremiumWritten = FHE.asEuint64(0);
        _totalClaimsReserved = FHE.asEuint64(0);
        _totalClaimsPaid = FHE.asEuint64(0);
        _lossRatio = FHE.asEuint64(0);
        FHE.allowThis(_insuranceFundBalance);
        FHE.allowThis(_totalGrossPremiumWritten);
        FHE.allowThis(_totalClaimsReserved);
        FHE.allowThis(_totalClaimsPaid);
        FHE.allowThis(_lossRatio);
        authorizedUnderwriter[msg.sender] = true;
    }

    modifier onlyUnderwriter() {
        require(authorizedUnderwriter[msg.sender], "Not authorized underwriter");
        _;
    }

    function grantUnderwriterAccess(address uw) external onlyOwner {
        authorizedUnderwriter[uw] = true;
    }

    function submitRiskProfile(
        address insured,
        IndustryVertical industry,
        externalEuint64 encRevenue, bytes calldata revProof,
        externalEuint64 encRecords, bytes calldata recProof,
        externalEuint64 encCyberMaturity, bytes calldata cmProof,
        externalEuint64 encMFARate, bytes calldata mfaProof,
        externalEuint64 encPatchingScore, bytes calldata psProof,
        externalEuint64 encBackupScore, bytes calldata bsProof,
        externalEuint32 encBreachCount, bytes calldata bcProof,
        externalEuint64 encPriorLoss, bytes calldata plProof,
        bool mspManaged
    ) external onlyUnderwriter returns (bytes32 profileId) {
        profileId = keccak256(abi.encodePacked(insured, block.timestamp));
        euint64 revenue = FHE.fromExternal(encRevenue, revProof);
        euint64 records = FHE.fromExternal(encRecords, recProof);
        euint64 cyberMaturity = FHE.fromExternal(encCyberMaturity, cmProof);
        euint64 mfaRate = FHE.fromExternal(encMFARate, mfaProof);
        euint64 patchingScore = FHE.fromExternal(encPatchingScore, psProof);
        euint64 backupScore = FHE.fromExternal(encBackupScore, bsProof);
        euint32 breachCount = FHE.fromExternal(encBreachCount, bcProof);
        euint64 priorLoss = FHE.fromExternal(encPriorLoss, plProof);

        CyberRiskProfile storage _s0 = riskProfiles[profileId];
        _s0.industry = industry;
        _s0.annualRevenue = revenue;
        _s0.recordsStored = records;
        _s0.cyberMaturityScore = cyberMaturity;
        _s0.endpointProtectionScore = FHE.asEuint64(0);
        _s0.mfaAdoptionRate = mfaRate;
        _s0.patchingVelocityScore = patchingScore;
        _s0.backupRecoveryScore = backupScore;
        _s0.thirdPartyRiskScore = FHE.asEuint64(0);
        _s0.priorBreachLossAmount = priorLoss;
        _s0.priorBreachCount = breachCount;
        _s0.lastAssessmentDate = block.timestamp;
        _s0.mspManaged = mspManaged;

        FHE.allowThis(revenue); FHE.allow(revenue, msg.sender);
        FHE.allowThis(records); FHE.allow(records, msg.sender);
        FHE.allowThis(cyberMaturity); FHE.allow(cyberMaturity, msg.sender);
        FHE.allowThis(mfaRate); FHE.allow(mfaRate, msg.sender);
        FHE.allowThis(patchingScore); FHE.allow(patchingScore, msg.sender);
        FHE.allowThis(backupScore); FHE.allow(backupScore, msg.sender);
        FHE.allowThis(breachCount); FHE.allow(breachCount, msg.sender);
        FHE.allowThis(priorLoss); FHE.allow(priorLoss, msg.sender);
        FHE.allowThis(riskProfiles[profileId].endpointProtectionScore);
        FHE.allowThis(riskProfiles[profileId].thirdPartyRiskScore);

        emit RiskProfileUpdated(profileId);
    }

    function quotePolicy(
        bytes32 profileId,
        externalEuint64 encPremium, bytes calldata premProof,
        externalEuint64 encAggLimit, bytes calldata alProof,
        externalEuint64 encRetention, bytes calldata retProof,
        externalEuint64 encRansomSublimit, bytes calldata rsProof,
        externalEuint64 encBECSublimit, bytes calldata becProof,
        externalEuint64 encBISublimit, bytes calldata biProof,
        uint256 inceptionDate,
        uint256 expiryDate,
        bool coInsurance,
        uint8 coPercent
    ) external onlyUnderwriter returns (bytes32 policyId) {
        address insured = address(uint160(uint256(profileId) >> 96)); // extract from hash
        euint64 premium = FHE.fromExternal(encPremium, premProof);
        euint64 aggLimit = FHE.fromExternal(encAggLimit, alProof);
        euint64 retention = FHE.fromExternal(encRetention, retProof);
        euint64 ransomSublimit = FHE.fromExternal(encRansomSublimit, rsProof);
        euint64 becSublimit = FHE.fromExternal(encBECSublimit, becProof);
        euint64 biSublimit = FHE.fromExternal(encBISublimit, biProof);

        policyId = keccak256(abi.encodePacked(profileId, inceptionDate, block.timestamp));

        CyberPolicy storage _s1 = policies[policyId];
        _s1.insured = insured;
        _s1.status = PolicyStatus.QUOTED;
        _s1.annualPremium = premium;
        _s1.aggregateLimit = aggLimit;
        _s1.retentionAmount = retention;
        _s1.sublimitRansomware = ransomSublimit;
        _s1.sublimitBEC = becSublimit;
        _s1.sublimitBI = biSublimit;
        _s1.retroactivePremiumAdjust = FHE.asEuint64(0);
        _s1.earnedPremium = FHE.asEuint64(0);
        _s1.inceptionDate = inceptionDate;
        _s1.expiryDate = expiryDate;
        _s1.coInsurance = coInsurance;
        _s1.coInsurancePercent = coPercent;

        FHE.allowThis(premium); FHE.allow(premium, insured);
        FHE.allowThis(aggLimit); FHE.allow(aggLimit, insured);
        FHE.allowThis(retention); FHE.allow(retention, insured);
        FHE.allowThis(ransomSublimit); FHE.allow(ransomSublimit, insured);
        FHE.allowThis(becSublimit); FHE.allow(becSublimit, insured);
        FHE.allowThis(biSublimit); FHE.allow(biSublimit, insured);
        FHE.allowThis(policies[policyId].retroactivePremiumAdjust);
        FHE.allowThis(policies[policyId].earnedPremium);

        emit PolicyQuoted(policyId, insured);
    }

    function bindPolicy(bytes32 policyId) external onlyUnderwriter {
        CyberPolicy storage pol = policies[policyId];
        require(pol.status == PolicyStatus.QUOTED, "Not in quoted status");
        pol.status = PolicyStatus.ACTIVE;
        insuredToPolicy[pol.insured] = policyId;
        _totalGrossPremiumWritten = FHE.add(_totalGrossPremiumWritten, pol.annualPremium);
        _insuranceFundBalance = FHE.add(_insuranceFundBalance, pol.annualPremium);
        FHE.allowThis(_totalGrossPremiumWritten);
        FHE.allowThis(_insuranceFundBalance);
        emit PolicyBound(policyId);
    }

    function reportClaim(
        bytes32 policyId,
        CoverageType coverageType,
        externalEuint64 encClaimedAmount, bytes calldata caProof,
        externalEuint64 encForensicsCost, bytes calldata fcProof,
        externalEuint64 encPRCost, bytes calldata prcProof,
        uint256 incidentDate,
        bool litigationInvolved,
        bool regulatoryRequired
    ) external nonReentrant returns (bytes32 claimId) {
        CyberPolicy storage pol = policies[policyId];
        require(pol.status == PolicyStatus.ACTIVE, "Policy not active");
        require(pol.insured == msg.sender, "Not the insured");

        euint64 claimedAmount = FHE.fromExternal(encClaimedAmount, caProof);
        euint64 forensicsCost = FHE.fromExternal(encForensicsCost, fcProof);
        euint64 prCost = FHE.fromExternal(encPRCost, prcProof);

        // Net claim after retention
        euint64 netClaim = FHE.select(FHE.ge(claimedAmount, pol.retentionAmount),
            FHE.sub(claimedAmount, pol.retentionAmount),
            FHE.asEuint64(0));

        // Cap at aggregate limit
        netClaim = FHE.select(FHE.ge(netClaim, pol.aggregateLimit), pol.aggregateLimit, netClaim);

        claimId = keccak256(abi.encodePacked(policyId, incidentDate, block.timestamp));

        Claim storage _s2 = claims[claimId];
        _s2.policyId = policyId;
        _s2.insured = msg.sender;
        _s2.coverageType = coverageType;
        _s2.claimedAmount = claimedAmount;
        _s2.reservedAmount = netClaim;
        _s2.paidAmount = FHE.asEuint64(0);
        _s2.subrogationRecovered = FHE.asEuint64(0);
        _s2.publicRelationsCosts = prCost;
        _s2.forensicsCosts = forensicsCost;
        _s2.incidentDate = incidentDate;
        _s2.reportedDate = block.timestamp;
        _s2.litigationInvolved = litigationInvolved;
        _s2.regulatoryNotificationRequired = regulatoryRequired;

        pol.status = PolicyStatus.CLAIMED;
        _totalClaimsReserved = FHE.add(_totalClaimsReserved, netClaim);

        FHE.allowThis(claimedAmount); FHE.allow(claimedAmount, msg.sender);
        FHE.allowThis(netClaim); FHE.allow(netClaim, msg.sender);
        FHE.allowThis(forensicsCost); FHE.allow(forensicsCost, msg.sender);
        FHE.allowThis(prCost); FHE.allow(prCost, msg.sender);
        FHE.allowThis(claims[claimId].paidAmount);
        FHE.allow(claims[claimId].paidAmount, msg.sender);
        FHE.allowThis(claims[claimId].subrogationRecovered);
        FHE.allowThis(_totalClaimsReserved);

        emit ClaimReported(claimId, policyId, coverageType);
    }

    function settleClaim(bytes32 claimId) external onlyUnderwriter {
        Claim storage clm = claims[claimId];
        clm.paidAmount = clm.reservedAmount;
        _totalClaimsPaid = FHE.add(_totalClaimsPaid, clm.paidAmount);
        _insuranceFundBalance = FHE.sub(_insuranceFundBalance,
            FHE.select(FHE.ge(_insuranceFundBalance, clm.paidAmount),
                clm.paidAmount, _insuranceFundBalance));
        _lossRatio = FHE.mul(_totalClaimsPaid, FHE.asEuint64(10000)); // simplified: div by premiums omitted
        FHE.allowThis(clm.paidAmount);
        FHE.allow(clm.paidAmount, clm.insured);
        FHE.allowThis(_totalClaimsPaid);
        FHE.allowThis(_insuranceFundBalance);
        FHE.allowThis(_lossRatio);
        FHE.allowTransient(clm.paidAmount, clm.insured);
        emit ClaimPaid(claimId);
    }

    function allowPortfolioMetricsView(address viewer) external onlyOwner {
        FHE.allow(_totalGrossPremiumWritten, viewer);
        FHE.allow(_totalClaimsReserved, viewer);
        FHE.allow(_totalClaimsPaid, viewer);
        FHE.allow(_lossRatio, viewer);
        FHE.allow(_insuranceFundBalance, viewer);
    }
}
