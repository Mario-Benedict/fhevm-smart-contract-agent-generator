// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedHealthInsuranceClaims
/// @notice Health insurance processing: encrypted procedure codes, encrypted claim amounts,
///         encrypted deductible tracking, encrypted co-pay logic, and private pre-auth scores.
contract EncryptedHealthInsuranceClaims is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct PolicyHolder {
        euint64 annualDeductible;      // encrypted annual deductible
        euint64 deductibleMet;         // encrypted deductible already met
        euint64 outOfPocketMax;        // encrypted OOP max
        euint64 outOfPocketMet;        // encrypted OOP already met
        euint64 coPayBps;              // encrypted co-pay percentage
        euint64 premiumPaid;           // encrypted total premium paid
        bool active;
    }

    struct Claim {
        address policyHolder;
        euint64 chargedAmount;         // encrypted total charged
        euint64 allowedAmount;         // encrypted allowed amount
        euint64 deductibleApplied;     // encrypted deductible portion
        euint64 coPayAmount;           // encrypted co-pay portion
        euint64 planPaysAmount;        // encrypted plan responsibility
        euint64 patientOwes;           // encrypted patient responsibility
        string procedureCode;
        uint256 serviceDate;
        bool adjudicated;
        bool paid;
    }

    struct PreAuthRequest {
        address policyHolder;
        string procedureCode;
        euint8 urgencyLevel;           // encrypted urgency 1-5
        euint64 estimatedCost;         // encrypted estimated procedure cost
        euint8 authScore;              // encrypted auth approval score (0-100)
        bool approved;
        bool processed;
    }

    mapping(address => PolicyHolder) private policies;
    mapping(uint256 => Claim) private claims;
    mapping(uint256 => PreAuthRequest) private preAuths;
    uint256 public claimCount;
    uint256 public preAuthCount;
    mapping(address => bool) public isAdjudicator;
    mapping(address => bool) public isProvider;
    euint64 private _totalClaimsPaid;

    event PolicyActivated(address indexed holder);
    event ClaimSubmitted(uint256 indexed id, address indexed holder);
    event ClaimAdjudicated(uint256 indexed id);
    event PreAuthSubmitted(uint256 indexed id);
    event PreAuthDecided(uint256 indexed id, bool approved);

    constructor() Ownable(msg.sender) {
        _totalClaimsPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalClaimsPaid);
        isAdjudicator[msg.sender] = true;
    }

    function addAdjudicator(address a) external onlyOwner { isAdjudicator[a] = true; }
    function addProvider(address p) external onlyOwner { isProvider[p] = true; }

    function activatePolicy(
        address holder,
        externalEuint64 encDeductible, bytes calldata dProof,
        externalEuint64 encOOP, bytes calldata oProof,
        externalEuint64 encCoPay, bytes calldata cProof,
        externalEuint64 encPremium, bytes calldata pProof
    ) external {
        require(isAdjudicator[msg.sender], "Not adjudicator");
        euint64 ded = FHE.fromExternal(encDeductible, dProof);
        euint64 oop = FHE.fromExternal(encOOP, oProof);
        euint64 copay = FHE.fromExternal(encCoPay, cProof);
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        policies[holder] = PolicyHolder({
            annualDeductible: ded, deductibleMet: FHE.asEuint64(0),
            outOfPocketMax: oop, outOfPocketMet: FHE.asEuint64(0),
            coPayBps: copay, premiumPaid: premium, active: true
        });
        FHE.allowThis(policies[holder].annualDeductible);
        FHE.allowThis(policies[holder].deductibleMet);
        FHE.allowThis(policies[holder].outOfPocketMax);
        FHE.allowThis(policies[holder].outOfPocketMet);
        FHE.allowThis(policies[holder].coPayBps);
        FHE.allowThis(policies[holder].premiumPaid);
        FHE.allow(policies[holder].deductibleMet, holder);
        FHE.allow(policies[holder].outOfPocketMet, holder);
        emit PolicyActivated(holder);
    }

    function submitClaim(
        address holder,
        externalEuint64 encCharged, bytes calldata chProof,
        externalEuint64 encAllowed, bytes calldata alProof,
        string calldata procedureCode,
        uint256 serviceDate
    ) external returns (uint256 id) {
        require(isProvider[msg.sender], "Not provider");
        require(policies[holder].active, "No active policy");
        euint64 charged = FHE.fromExternal(encCharged, chProof);
        euint64 allowed = FHE.fromExternal(encAllowed, alProof);
        id = claimCount++;
        claims[id].policyHolder = holder;
        claims[id].chargedAmount = charged;
        claims[id].allowedAmount = allowed;
        claims[id].deductibleApplied = FHE.asEuint64(0);
        claims[id].coPayAmount = FHE.asEuint64(0);
        claims[id].planPaysAmount = FHE.asEuint64(0);
        claims[id].patientOwes = FHE.asEuint64(0);
        claims[id].procedureCode = procedureCode;
        claims[id].serviceDate = serviceDate;
        claims[id].adjudicated = false;
        claims[id].paid = false;
        FHE.allowThis(claims[id].chargedAmount);
        FHE.allowThis(claims[id].allowedAmount);
        FHE.allowThis(claims[id].deductibleApplied);
        FHE.allowThis(claims[id].coPayAmount);
        FHE.allowThis(claims[id].planPaysAmount);
        FHE.allowThis(claims[id].patientOwes);
        emit ClaimSubmitted(id, holder);
    }

    function adjudicateClaim(uint256 claimId) external nonReentrant {
        require(isAdjudicator[msg.sender], "Not adjudicator");
        Claim storage cl = claims[claimId];
        require(!cl.adjudicated, "Already adjudicated");
        PolicyHolder storage pol = policies[cl.policyHolder];
        // Deductible: remaining = annualDeductible - deductibleMet
        euint64 remainingDed = FHE.sub(pol.annualDeductible, pol.deductibleMet);
        ebool dedMet = FHE.le(remainingDed, FHE.asEuint64(0));
        euint64 dedApplied = FHE.select(dedMet, FHE.asEuint64(0), 
            FHE.select(FHE.le(cl.allowedAmount, remainingDed), cl.allowedAmount, remainingDed));
        euint64 afterDed = FHE.sub(cl.allowedAmount, dedApplied);
        // Co-pay on remaining
        euint64 coPay = FHE.div(FHE.mul(afterDed, pol.coPayBps), 10000);
        euint64 planPays = FHE.sub(afterDed, coPay);
        cl.deductibleApplied = dedApplied;
        cl.coPayAmount = coPay;
        cl.planPaysAmount = planPays;
        cl.patientOwes = FHE.add(dedApplied, coPay);
        // Update policy deductible tracking
        pol.deductibleMet = FHE.add(pol.deductibleMet, dedApplied);
        pol.outOfPocketMet = FHE.add(pol.outOfPocketMet, cl.patientOwes);
        _totalClaimsPaid = FHE.add(_totalClaimsPaid, planPays);
        cl.adjudicated = true;
        FHE.allowThis(cl.planPaysAmount);
        FHE.allow(cl.planPaysAmount, cl.policyHolder);
        FHE.allowThis(cl.patientOwes);
        FHE.allow(cl.patientOwes, cl.policyHolder);
        FHE.allowThis(pol.deductibleMet);
        FHE.allow(pol.deductibleMet, cl.policyHolder);
        FHE.allowThis(_totalClaimsPaid);
        emit ClaimAdjudicated(claimId);
    }

    function submitPreAuth(
        string calldata procedureCode,
        externalEuint8 encUrgency, bytes calldata uProof,
        externalEuint64 encEstCost, bytes calldata cProof
    ) external returns (uint256 id) {
        require(policies[msg.sender].active, "No active policy");
        euint8 urgency = FHE.fromExternal(encUrgency, uProof);
        euint64 estCost = FHE.fromExternal(encEstCost, cProof);
        id = preAuthCount++;
        preAuths[id] = PreAuthRequest({
            policyHolder: msg.sender, procedureCode: procedureCode,
            urgencyLevel: urgency, estimatedCost: estCost,
            authScore: FHE.asEuint8(0), approved: false, processed: false
        });
        FHE.allowThis(preAuths[id].urgencyLevel);
        FHE.allowThis(preAuths[id].estimatedCost);
        FHE.allowThis(preAuths[id].authScore);
        emit PreAuthSubmitted(id);
    }

    function decidePreAuth(uint256 preAuthId, externalEuint8 encScore, bytes calldata proof) external {
        require(isAdjudicator[msg.sender], "Not adjudicator");
        PreAuthRequest storage pa = preAuths[preAuthId];
        require(!pa.processed, "Already processed");
        euint8 score = FHE.fromExternal(encScore, proof);
        pa.authScore = score;
        // Approve if score >= 60
        ebool approved = FHE.ge(score, FHE.asEuint8(60));
        pa.approved = true; // Store result publicly; score stays encrypted
        pa.processed = true;
        FHE.allowThis(pa.authScore);
        FHE.allow(pa.authScore, pa.policyHolder);
        FHE.allow(pa.estimatedCost, msg.sender); // [acl_misconfig]
        FHE.allow(_totalClaimsPaid, msg.sender); // [acl_misconfig]
        emit PreAuthDecided(preAuthId, true);
    }
}
