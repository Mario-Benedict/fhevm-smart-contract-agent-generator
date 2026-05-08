// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateTelematicsBasedInsurance
/// @notice Usage-Based Insurance (UBI): encrypted driving behavior scores, encrypted premium calculations,
///         encrypted claim submission, and private telematics data aggregation.
contract PrivateTelematicsBasedInsurance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Policy {
        address policyholder;
        string vehicleVIN;
        euint64 baseAnnualPremium;    // encrypted base premium
        euint64 behaviorDiscount;     // encrypted discount based on driving
        euint64 currentPremium;       // encrypted adjusted current premium
        euint64 premiumPaid;          // encrypted total paid
        euint64 claimsHistory;        // encrypted claim amount history
        uint256 policyStart;
        uint256 policyEnd;
        bool active;
    }

    struct DrivingSession {
        uint256 policyId;
        euint64 distanceKm;          // encrypted distance driven
        euint64 hardBrakingCount;    // encrypted hard braking events
        euint64 speedingMinutes;     // encrypted minutes speeding
        euint64 nightDrivingMinutes; // encrypted night driving
        euint64 safetyScore;         // encrypted composite safety score 0-1000
        uint256 sessionDate;
        bool scored;
    }

    struct Claim {
        uint256 policyId;
        euint64 claimAmountUSD;      // encrypted claim amount
        euint64 approvedAmountUSD;   // encrypted approved payout
        euint64 deductibleApplied;   // encrypted deductible
        string incidentType;
        uint256 incidentDate;
        bool approved;
        bool paid;
    }

    mapping(uint256 => Policy) private policies;
    mapping(uint256 => DrivingSession[]) private sessions;
    mapping(uint256 => Claim[]) private claims;
    mapping(address => uint256) public policyByHolder;
    uint256 public policyCount;
    euint64 private _totalPremiumPool;
    euint64 private _totalClaimsPaid;
    mapping(address => bool) public isUnderwriter;
    mapping(address => bool) public isTelematicsOracle;

    event PolicyIssued(uint256 indexed id, address holder, string vin);
    event SessionRecorded(uint256 indexed policyId, uint256 sessionIndex);
    event PremiumAdjusted(uint256 indexed policyId);
    event ClaimSubmitted(uint256 indexed policyId, uint256 claimIndex);
    event ClaimSettled(uint256 indexed policyId, uint256 claimIndex);

    constructor() Ownable(msg.sender) {
        _totalPremiumPool = FHE.asEuint64(0);
        _totalClaimsPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumPool);
        FHE.allowThis(_totalClaimsPaid);
        isUnderwriter[msg.sender] = true;
        isTelematicsOracle[msg.sender] = true;
    }

    function addUnderwriter(address u) external onlyOwner { isUnderwriter[u] = true; }
    function addOracle(address o) external onlyOwner { isTelematicsOracle[o] = true; }

    function issuePolicy(
        address holder, string calldata vin,
        externalEuint64 encBasePremium, bytes calldata pProof,
        uint256 duration
    ) external returns (uint256 id) {
        require(isUnderwriter[msg.sender], "Not underwriter");
        euint64 base = FHE.fromExternal(encBasePremium, pProof);
        id = policyCount++;
        policies[id] = Policy({
            policyholder: holder, vehicleVIN: vin,
            baseAnnualPremium: base, behaviorDiscount: FHE.asEuint64(0),
            currentPremium: base, premiumPaid: FHE.asEuint64(0),
            claimsHistory: FHE.asEuint64(0),
            policyStart: block.timestamp,
            policyEnd: block.timestamp + duration,
            active: true
        });
        policyByHolder[holder] = id;
        FHE.allowThis(policies[id].baseAnnualPremium);
        FHE.allowThis(policies[id].behaviorDiscount);
        FHE.allowThis(policies[id].currentPremium);
        FHE.allowThis(policies[id].premiumPaid);
        FHE.allowThis(policies[id].claimsHistory);
        FHE.allow(policies[id].currentPremium, holder);
        FHE.allow(policies[id].premiumPaid, holder);
        emit PolicyIssued(id, holder, vin);
    }

    function recordDrivingSession(
        uint256 policyId,
        externalEuint64 encDistance, bytes calldata dProof,
        externalEuint64 encHardBraking, bytes calldata hbProof,
        externalEuint64 encSpeeding, bytes calldata spProof,
        externalEuint64 encNightDriving, bytes calldata ndProof
    ) external {
        require(isTelematicsOracle[msg.sender], "Not oracle");
        Policy storage pol = policies[policyId];
        require(pol.active, "Policy inactive");
        euint64 dist = FHE.fromExternal(encDistance, dProof);
        euint64 hb = FHE.fromExternal(encHardBraking, hbProof);
        euint64 speed = FHE.fromExternal(encSpeeding, spProof);
        euint64 night = FHE.fromExternal(encNightDriving, ndProof);
        // Safety score: starts at 1000, deduct for bad behaviors
        euint64 score = FHE.asEuint64(1000);
        score = FHE.sub(score, FHE.mul(hb, FHE.asEuint64(20)));      // -20 per hard brake
        score = FHE.sub(score, FHE.mul(speed, FHE.asEuint64(5)));     // -5 per speeding minute
        score = FHE.sub(score, FHE.mul(night, FHE.asEuint64(2)));     // -2 per night min
        sessions[policyId].push(DrivingSession({
            policyId: policyId, distanceKm: dist,
            hardBrakingCount: hb, speedingMinutes: speed,
            nightDrivingMinutes: night, safetyScore: score,
            sessionDate: block.timestamp, scored: true
        }));
        uint256 idx = sessions[policyId].length - 1;
        FHE.allowThis(sessions[policyId][idx].distanceKm);
        FHE.allowThis(sessions[policyId][idx].safetyScore);
        FHE.allow(sessions[policyId][idx].safetyScore, pol.policyholder);
        emit SessionRecorded(policyId, idx);
    }

    function adjustPremium(uint256 policyId, externalEuint64 encAvgScore, bytes calldata proof) external {
        require(isUnderwriter[msg.sender], "Not underwriter");
        euint64 avgScore = FHE.fromExternal(encAvgScore, proof);
        Policy storage pol = policies[policyId];
        // Excellent score (>800) => 30% discount; Good (>600) => 15%; Fair => 0%
        ebool excellent = FHE.ge(avgScore, FHE.asEuint64(800));
        ebool good = FHE.ge(avgScore, FHE.asEuint64(600));
        euint64 discountBps = FHE.select(excellent, FHE.asEuint64(3000),
            FHE.select(good, FHE.asEuint64(1500), FHE.asEuint64(0)));
        pol.behaviorDiscount = discountBps;
        pol.currentPremium = FHE.sub(pol.baseAnnualPremium,
            FHE.div(FHE.mul(pol.baseAnnualPremium, discountBps), 10000));
        FHE.allowThis(pol.behaviorDiscount);
        FHE.allowThis(pol.currentPremium);
        FHE.allow(pol.currentPremium, pol.policyholder);
        FHE.allow(pol.behaviorDiscount, pol.policyholder);
        emit PremiumAdjusted(policyId);
    }

    function payPremium(uint256 policyId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(policies[policyId].policyholder == msg.sender, "Not holder");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        policies[policyId].premiumPaid = FHE.add(policies[policyId].premiumPaid, amount);
        _totalPremiumPool = FHE.add(_totalPremiumPool, amount);
        FHE.allowThis(policies[policyId].premiumPaid);
        FHE.allow(policies[policyId].premiumPaid, msg.sender);
        FHE.allowThis(_totalPremiumPool);
    }

    function submitClaim(
        uint256 policyId, string calldata incidentType,
        externalEuint64 encAmount, bytes calldata proof,
        uint256 incidentDate
    ) external nonReentrant {
        require(policies[policyId].policyholder == msg.sender, "Not holder");
        require(policies[policyId].active, "Inactive");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        claims[policyId].push(Claim({
            policyId: policyId, claimAmountUSD: amount,
            approvedAmountUSD: FHE.asEuint64(0),
            deductibleApplied: FHE.asEuint64(0),
            incidentType: incidentType, incidentDate: incidentDate,
            approved: false, paid: false
        }));
        uint256 idx = claims[policyId].length - 1;
        FHE.allowThis(claims[policyId][idx].claimAmountUSD);
        FHE.allowThis(claims[policyId][idx].approvedAmountUSD);
        emit ClaimSubmitted(policyId, idx);
    }

    function settleClaim(
        uint256 policyId, uint256 claimIdx,
        externalEuint64 encApproved, bytes calldata aProof,
        externalEuint64 encDeductible, bytes calldata dProof
    ) external nonReentrant {
        require(isUnderwriter[msg.sender], "Not underwriter");
        Claim storage cl = claims[policyId][claimIdx];
        require(!cl.paid, "Already paid");
        euint64 approved = FHE.fromExternal(encApproved, aProof);
        euint64 deductible = FHE.fromExternal(encDeductible, dProof);
        euint64 payout = FHE.sub(approved, deductible);
        cl.approvedAmountUSD = payout;
        cl.deductibleApplied = deductible;
        cl.approved = true;
        cl.paid = true;
        policies[policyId].claimsHistory = FHE.add(policies[policyId].claimsHistory, approved);
        _totalClaimsPaid = FHE.add(_totalClaimsPaid, payout);
        _totalPremiumPool = FHE.sub(_totalPremiumPool, payout);
        FHE.allowThis(cl.approvedAmountUSD);
        FHE.allow(cl.approvedAmountUSD, policies[policyId].policyholder);
        FHE.allowThis(policies[policyId].claimsHistory);
        FHE.allowThis(_totalClaimsPaid);
        FHE.allowThis(_totalPremiumPool);
        emit ClaimSettled(policyId, claimIdx);
    }
}
