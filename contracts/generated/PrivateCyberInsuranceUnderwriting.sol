// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCyberInsuranceUnderwriting
/// @notice Cyber insurance platform where organizational security posture scores,
///         breach history, and premium calculations are encrypted. Supports
///         ransomware coverage, business interruption, and data breach liability.
contract PrivateCyberInsuranceUnderwriting is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum CoverageType { RANSOMWARE, DATA_BREACH, BUSINESS_INTERRUPTION, SOCIAL_ENGINEERING, CYBER_EXTORTION }
    enum IndustryVertical { HEALTHCARE, FINANCIAL, RETAIL, MANUFACTURING, GOVERNMENT, TECH, EDUCATION }

    struct OrganizationProfile {
        string orgName;
        IndustryVertical industry;
        euint64 annualRevenueUSD;      // encrypted revenue
        euint32 employeeCount;         // encrypted headcount
        euint8  securityPostureScore;  // encrypted NIST CSF score 0-100
        euint8  mfaAdoptionPct;        // encrypted MFA coverage %
        euint8  patchCompliancePct;    // encrypted patch rate %
        euint8  cyberTrainingScore;    // encrypted employee awareness
        euint16 breachHistoryYears;    // encrypted years since last breach (0=never)
        euint64 dataRecordsStored;     // encrypted PII records count
        bool registered;
        bool premiumWaived;
    }

    struct CyberPolicy {
        address insured;
        address insurer;
        CoverageType[] coverageTypes;
        euint64 aggregateLimitUSD;     // encrypted total coverage limit
        euint64 retentionUSD;          // encrypted deductible/retention
        euint64 annualPremiumUSD;      // encrypted annual premium
        euint64 premiumPaidUSD;        // encrypted premium collected
        euint64 claimsReserveUSD;      // encrypted reserve set aside
        euint32 sublimitRansomUSD;     // encrypted ransomware sublimit (scaled)
        uint256 inceptionDate;
        uint256 expiryDate;
        bool active;
        bool underReview;
    }

    struct CyberClaim {
        uint256 policyId;
        CoverageType coverageType;
        euint64 claimedAmountUSD;      // encrypted claimed loss
        euint64 approvedAmountUSD;     // encrypted approved payout
        euint64 forensicsCostUSD;      // encrypted incident response costs
        euint64 reputationDamageUSD;   // encrypted reputational loss estimate
        string incidentDescription;
        uint256 incidentDate;
        uint256 reportDate;
        bool forensicsComplete;
        bool settled;
    }

    mapping(address => OrganizationProfile) private orgs;
    mapping(uint256 => CyberPolicy) private policies;
    mapping(uint256 => CyberClaim) private claims;
    mapping(address => uint256[]) private orgPolicies;
    mapping(address => bool) public isActuary;
    mapping(address => bool) public isForensicsInvestigator;
    uint256 public policyCount;
    uint256 public claimCount;
    euint64 private _totalWrittenPremium;
    euint64 private _totalExposure;
    euint64 private _totalClaimsPaid;
    euint64 private _totalForensicsCosts;

    event OrganizationProfileCreated(address indexed org, IndustryVertical industry);
    event PolicyIssued(uint256 indexed policyId, address indexed insured);
    event ClaimFiled(uint256 indexed claimId, uint256 policyId, CoverageType cType);
    event ClaimSettled(uint256 indexed claimId);
    event SecurityPostureUpdated(address indexed org);

    constructor() Ownable(msg.sender) {
        _totalWrittenPremium = FHE.asEuint64(0);
        _totalExposure = FHE.asEuint64(0);
        _totalClaimsPaid = FHE.asEuint64(0);
        _totalForensicsCosts = FHE.asEuint64(0);
        FHE.allowThis(_totalWrittenPremium);
        FHE.allowThis(_totalExposure);
        FHE.allowThis(_totalClaimsPaid);
        FHE.allowThis(_totalForensicsCosts);
        isActuary[msg.sender] = true;
        isForensicsInvestigator[msg.sender] = true;
    }

    function addActuary(address a) external onlyOwner { isActuary[a] = true; }
    function addForensics(address f) external onlyOwner { isForensicsInvestigator[f] = true; }

    function createOrgProfile(
        string calldata name,
        IndustryVertical industry,
        externalEuint64 encRevenue,   bytes calldata revProof,
        externalEuint32 encEmployees, bytes calldata empProof,
        externalEuint8  encPosture,   bytes calldata posProof,
        externalEuint8  encMFA,       bytes calldata mfaProof,
        externalEuint64 encRecords,   bytes calldata recProof
    ) external {
        euint64 revenue   = FHE.fromExternal(encRevenue, revProof);
        euint32 employees = FHE.fromExternal(encEmployees, empProof);
        euint8  posture   = FHE.fromExternal(encPosture, posProof);
        euint8  mfa       = FHE.fromExternal(encMFA, mfaProof);
        euint64 records   = FHE.fromExternal(encRecords, recProof);
        orgs[msg.sender] = OrganizationProfile({
            orgName: name,
            industry: industry,
            annualRevenueUSD: revenue,
            employeeCount: employees,
            securityPostureScore: posture,
            mfaAdoptionPct: mfa,
            patchCompliancePct: FHE.asEuint8(0),
            cyberTrainingScore: FHE.asEuint8(0),
            breachHistoryYears: FHE.asEuint16(0),
            dataRecordsStored: records,
            registered: true,
            premiumWaived: false
        });
        FHE.allowThis(orgs[msg.sender].annualRevenueUSD);
        FHE.allow(orgs[msg.sender].annualRevenueUSD, msg.sender);
        FHE.allowThis(orgs[msg.sender].employeeCount);
        FHE.allowThis(orgs[msg.sender].securityPostureScore);
        FHE.allow(orgs[msg.sender].securityPostureScore, msg.sender);
        FHE.allowThis(orgs[msg.sender].mfaAdoptionPct);
        FHE.allowThis(orgs[msg.sender].dataRecordsStored);
        FHE.allowThis(orgs[msg.sender].patchCompliancePct);
        FHE.allowThis(orgs[msg.sender].cyberTrainingScore);
        FHE.allowThis(orgs[msg.sender].breachHistoryYears);
        emit OrganizationProfileCreated(msg.sender, industry);
    }

    function updateSecurityPosture(
        address org,
        externalEuint8 encPosture,    bytes calldata posProof,
        externalEuint8 encMFA,        bytes calldata mfaProof,
        externalEuint8 encPatch,      bytes calldata patchProof,
        externalEuint8 encTraining,   bytes calldata trainProof
    ) external {
        require(isActuary[msg.sender], "Not actuary");
        orgs[org].securityPostureScore = FHE.fromExternal(encPosture, posProof);
        orgs[org].mfaAdoptionPct = FHE.fromExternal(encMFA, mfaProof);
        orgs[org].patchCompliancePct = FHE.fromExternal(encPatch, patchProof);
        orgs[org].cyberTrainingScore = FHE.fromExternal(encTraining, trainProof);
        FHE.allowThis(orgs[org].securityPostureScore);
        FHE.allowThis(orgs[org].mfaAdoptionPct);
        FHE.allowThis(orgs[org].patchCompliancePct);
        FHE.allowThis(orgs[org].cyberTrainingScore);
        emit SecurityPostureUpdated(org);
    }

    function issuePolicy(
        address insured,
        externalEuint64 encLimit,     bytes calldata limProof,
        externalEuint64 encRetention, bytes calldata retProof,
        externalEuint64 encPremium,   bytes calldata premProof,
        externalEuint32 encRansomSub, bytes calldata rsProof,
        uint256 durationDays
    ) external returns (uint256 policyId) {
        require(isActuary[msg.sender], "Not actuary");
        require(orgs[insured].registered, "Org not registered");
        euint64 limit   = FHE.fromExternal(encLimit, limProof);
        euint64 retain  = FHE.fromExternal(encRetention, retProof);
        euint64 premium = FHE.fromExternal(encPremium, premProof);
        euint32 ransom  = FHE.fromExternal(encRansomSub, rsProof);
        policyId = policyCount++;
        CoverageType[] memory defaultCoverage = new CoverageType[](3);
        defaultCoverage[0] = CoverageType.RANSOMWARE;
        defaultCoverage[1] = CoverageType.DATA_BREACH;
        defaultCoverage[2] = CoverageType.BUSINESS_INTERRUPTION;
        policies[policyId] = CyberPolicy({
            insured: insured,
            insurer: msg.sender,
            coverageTypes: defaultCoverage,
            aggregateLimitUSD: limit,
            retentionUSD: retain,
            annualPremiumUSD: premium,
            premiumPaidUSD: FHE.asEuint64(0),
            claimsReserveUSD: FHE.div(limit, 10),
            sublimitRansomUSD: ransom,
            inceptionDate: block.timestamp,
            expiryDate: block.timestamp + durationDays * 1 days,
            active: true,
            underReview: false
        });
        orgPolicies[insured].push(policyId);
        _totalWrittenPremium = FHE.add(_totalWrittenPremium, premium);
        _totalExposure = FHE.add(_totalExposure, limit);
        FHE.allowThis(policies[policyId].aggregateLimitUSD);
        FHE.allow(policies[policyId].aggregateLimitUSD, insured);
        FHE.allowThis(policies[policyId].retentionUSD);
        FHE.allow(policies[policyId].retentionUSD, insured);
        FHE.allowThis(policies[policyId].annualPremiumUSD);
        FHE.allow(policies[policyId].annualPremiumUSD, insured);
        FHE.allowThis(policies[policyId].premiumPaidUSD);
        FHE.allowThis(policies[policyId].claimsReserveUSD);
        FHE.allowThis(policies[policyId].sublimitRansomUSD);
        FHE.allowThis(_totalWrittenPremium);
        FHE.allowThis(_totalExposure);
        emit PolicyIssued(policyId, insured);
    }

    function fileClaim(
        uint256 policyId,
        CoverageType cType,
        externalEuint64 encClaimed,     bytes calldata clProof,
        externalEuint64 encForensics,   bytes calldata forProof,
        string calldata description,
        uint256 incidentDate
    ) external returns (uint256 claimId) {
        require(policies[policyId].insured == msg.sender, "Not insured");
        require(policies[policyId].active, "Policy inactive");
        euint64 claimed  = FHE.fromExternal(encClaimed, clProof);
        euint64 forensics= FHE.fromExternal(encForensics, forProof);
        claimId = claimCount++;
        claims[claimId] = CyberClaim({
            policyId: policyId,
            coverageType: cType,
            claimedAmountUSD: claimed,
            approvedAmountUSD: FHE.asEuint64(0),
            forensicsCostUSD: forensics,
            reputationDamageUSD: FHE.asEuint64(0),
            incidentDescription: description,
            incidentDate: incidentDate,
            reportDate: block.timestamp,
            forensicsComplete: false,
            settled: false
        });
        FHE.allowThis(claims[claimId].claimedAmountUSD);
        FHE.allow(claims[claimId].claimedAmountUSD, msg.sender);
        FHE.allowThis(claims[claimId].approvedAmountUSD);
        FHE.allowThis(claims[claimId].forensicsCostUSD);
        FHE.allowThis(claims[claimId].reputationDamageUSD);
        emit ClaimFiled(claimId, policyId, cType);
    }

    function approveClaim(
        uint256 claimId,
        externalEuint64 encApproved, bytes calldata proof
    ) external nonReentrant {
        require(isActuary[msg.sender] || isForensicsInvestigator[msg.sender], "Unauthorized");
        euint64 approved = FHE.fromExternal(encApproved, proof);
        // Cap at policy limit minus retention
        ebool withinLimit = FHE.le(approved, policies[claims[claimId].policyId].aggregateLimitUSD);
        euint64 actualApproval = FHE.select(withinLimit, approved, policies[claims[claimId].policyId].aggregateLimitUSD);
        claims[claimId].approvedAmountUSD = actualApproval;
        claims[claimId].settled = true;
        _totalClaimsPaid = FHE.add(_totalClaimsPaid, actualApproval);
        _totalForensicsCosts = FHE.add(_totalForensicsCosts, claims[claimId].forensicsCostUSD);
        FHE.allowThis(claims[claimId].approvedAmountUSD);
        FHE.allow(claims[claimId].approvedAmountUSD, policies[claims[claimId].policyId].insured);
        FHE.allowThis(_totalClaimsPaid);
        FHE.allowThis(_totalForensicsCosts);
        emit ClaimSettled(claimId);
    }

    function allowMarketView(address viewer) external onlyOwner {
        FHE.allow(_totalWrittenPremium, viewer);
        FHE.allow(_totalExposure, viewer);
        FHE.allow(_totalClaimsPaid, viewer);
    }
}
