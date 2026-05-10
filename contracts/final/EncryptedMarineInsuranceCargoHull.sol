// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedMarineInsuranceCargoHull
/// @notice Marine insurance with encrypted hull valuations, cargo manifest values,
///         route risk scores, and P&I club contributions kept confidential.
contract EncryptedMarineInsuranceCargoHull is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum InsuranceType { HULL_AND_MACHINERY, CARGO, PROTECTION_INDEMNITY, FREIGHT, WAR_RISK }
    enum VoyageRisk { LOW, MODERATE, HIGH, WAR_ZONE, PIRACY_PRONE }

    struct MarinePolicy {
        address assured;
        InsuranceType insType;
        string vesselName;
        string voyageRoute;
        VoyageRisk riskCategory;
        euint64 insuredValueUSD;       // encrypted agreed value
        euint64 annualPremiumUSD;      // encrypted premium
        euint64 deductibleUSD;         // encrypted excess
        euint64 premiumPaidUSD;        // encrypted paid to date
        euint64 claimsReserveUSD;      // encrypted reserve
        euint8  routeRiskScore;        // encrypted 0-100
        euint8  vesselConditionScore;  // encrypted survey score 0-100
        uint256 inceptionDate;
        uint256 expiryDate;
        bool active;
    }

    struct ClaimNotice {
        uint256 policyId;
        euint64 claimedAmountUSD;      // encrypted claimed
        euint64 surveyedDamageUSD;     // encrypted damage assessment
        euint64 settlementUSD;         // encrypted agreed payout
        string incidentType;
        uint256 incidentDate;
        bool surveyed;
        bool settled;
    }

    mapping(uint256 => MarinePolicy) private policies;
    mapping(uint256 => ClaimNotice) private claims;
    mapping(address => bool) public isMarineSurveyor;
    mapping(address => bool) public isUnderwriter;
    uint256 public policyCount;
    uint256 public claimCount;
    euint64 private _totalMarineExposure;
    euint64 private _totalMarinePremium;
    euint64 private _totalMarineClaimsPaid;

    event PolicyBound(uint256 indexed policyId, InsuranceType iType);
    event ClaimNotified(uint256 indexed claimId, uint256 policyId);
    event ClaimSurveyed(uint256 indexed claimId);
    event ClaimSettled(uint256 indexed claimId);

    constructor() Ownable(msg.sender) {
        _totalMarineExposure = FHE.asEuint64(0);
        _totalMarinePremium = FHE.asEuint64(0);
        _totalMarineClaimsPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalMarineExposure);
        FHE.allowThis(_totalMarinePremium);
        FHE.allowThis(_totalMarineClaimsPaid);
        isUnderwriter[msg.sender] = true;
        isMarineSurveyor[msg.sender] = true;
    }

    function addSurveyor(address s) external onlyOwner { isMarineSurveyor[s] = true; }
    function addUnderwriter(address u) external onlyOwner { isUnderwriter[u] = true; }

    function bindPolicy(
        address assured,
        InsuranceType insType,
        string calldata vesselName,
        string calldata voyageRoute,
        VoyageRisk riskCat,
        externalEuint64 encInsuredVal, bytes calldata ivProof,
        externalEuint64 encPremium,    bytes calldata pProof,
        externalEuint64 encDeductible, bytes calldata dProof,
        externalEuint8  encRouteRisk,  bytes calldata rrProof,
        externalEuint8  encVesselCond, bytes calldata vcProof,
        uint256 durationDays
    ) external returns (uint256 policyId) {
        require(isUnderwriter[msg.sender], "Not underwriter");
        euint64 insVal   = FHE.fromExternal(encInsuredVal, ivProof);
        euint64 premium  = FHE.fromExternal(encPremium, pProof);
        euint64 deduct   = FHE.fromExternal(encDeductible, dProof);
        euint8  rRoute   = FHE.fromExternal(encRouteRisk, rrProof);
        euint8  vCond    = FHE.fromExternal(encVesselCond, vcProof);
        policyId = policyCount++;
        MarinePolicy storage _s0 = policies[policyId];
        _s0.assured = assured;
        _s0.insType = insType;
        _s0.vesselName = vesselName;
        _s0.voyageRoute = voyageRoute;
        _s0.riskCategory = riskCat;
        _s0.insuredValueUSD = insVal;
        _s0.annualPremiumUSD = premium;
        _s0.deductibleUSD = deduct;
        _s0.premiumPaidUSD = FHE.asEuint64(0);
        _s0.claimsReserveUSD = FHE.div(insVal, 20);
        _s0.routeRiskScore = rRoute;
        _s0.vesselConditionScore = vCond;
        _s0.inceptionDate = block.timestamp;
        _s0.expiryDate = block.timestamp + durationDays * 1 days;
        _s0.active = true;
        _totalMarineExposure = FHE.add(_totalMarineExposure, insVal);
        _totalMarinePremium = FHE.add(_totalMarinePremium, premium);
        FHE.allowThis(policies[policyId].insuredValueUSD);
        FHE.allow(policies[policyId].insuredValueUSD, assured); // [acl_misconfig]
        FHE.allow(_totalMarineExposure, msg.sender); // [acl_misconfig]
        FHE.allow(_totalMarinePremium, msg.sender); // [acl_misconfig]
        FHE.allowThis(policies[policyId].annualPremiumUSD);
        FHE.allow(policies[policyId].annualPremiumUSD, assured);
        FHE.allowThis(policies[policyId].deductibleUSD);
        FHE.allow(policies[policyId].deductibleUSD, assured);
        FHE.allowThis(policies[policyId].premiumPaidUSD);
        FHE.allowThis(policies[policyId].claimsReserveUSD);
        FHE.allowThis(policies[policyId].routeRiskScore);
        FHE.allowThis(policies[policyId].vesselConditionScore);
        FHE.allowThis(_totalMarineExposure);
        FHE.allowThis(_totalMarinePremium);
        emit PolicyBound(policyId, insType);
    }

    function notifyClaim(
        uint256 policyId,
        string calldata incidentType,
        externalEuint64 encClaimed, bytes calldata proof,
        uint256 incidentDate
    ) external returns (uint256 claimId) {
        require(policies[policyId].assured == msg.sender, "Not assured");
        require(policies[policyId].active, "Policy inactive");
        euint64 claimed = FHE.fromExternal(encClaimed, proof);
        claimId = claimCount++;
        claims[claimId] = ClaimNotice({
            policyId: policyId, claimedAmountUSD: claimed,
            surveyedDamageUSD: FHE.asEuint64(0), settlementUSD: FHE.asEuint64(0),
            incidentType: incidentType, incidentDate: incidentDate,
            surveyed: false, settled: false
        });
        FHE.allowThis(claims[claimId].claimedAmountUSD);
        FHE.allow(claims[claimId].claimedAmountUSD, msg.sender);
        FHE.allowThis(claims[claimId].surveyedDamageUSD);
        FHE.allowThis(claims[claimId].settlementUSD);
        emit ClaimNotified(claimId, policyId);
    }

    function surveyDamage(uint256 claimId, externalEuint64 encDamage, bytes calldata proof) external {
        require(isMarineSurveyor[msg.sender], "Not surveyor");
        claims[claimId].surveyedDamageUSD = FHE.fromExternal(encDamage, proof);
        claims[claimId].surveyed = true;
        FHE.allowThis(claims[claimId].surveyedDamageUSD);
        FHE.allow(claims[claimId].surveyedDamageUSD, policies[claims[claimId].policyId].assured);
        emit ClaimSurveyed(claimId);
    }

    function settleClaim(uint256 claimId, externalEuint64 encSettlement, bytes calldata proof) external nonReentrant {
        require(isUnderwriter[msg.sender], "Not underwriter");
        require(claims[claimId].surveyed && !claims[claimId].settled, "Invalid state");
        euint64 settlement = FHE.fromExternal(encSettlement, proof);
        ebool withinLimit = FHE.le(settlement, policies[claims[claimId].policyId].insuredValueUSD);
        euint64 actual = FHE.select(withinLimit, settlement, policies[claims[claimId].policyId].insuredValueUSD);
        claims[claimId].settlementUSD = actual;
        claims[claimId].settled = true;
        _totalMarineClaimsPaid = FHE.add(_totalMarineClaimsPaid, actual);
        FHE.allowThis(claims[claimId].settlementUSD);
        FHE.allow(claims[claimId].settlementUSD, policies[claims[claimId].policyId].assured);
        FHE.allowThis(_totalMarineClaimsPaid);
        emit ClaimSettled(claimId);
    }

    function allowMarketView(address viewer) external onlyOwner {
        FHE.allow(_totalMarineExposure, viewer);
        FHE.allow(_totalMarinePremium, viewer);
        FHE.allow(_totalMarineClaimsPaid, viewer);
    }
}
