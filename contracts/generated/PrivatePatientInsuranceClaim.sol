// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivatePatientInsuranceClaim
/// @notice Health insurance claim processing: patients submit encrypted medical costs,
///         insurance validates against encrypted coverage limits, pays encrypted reimbursement.
contract PrivatePatientInsuranceClaim is ZamaEthereumConfig, Ownable {
    enum ClaimStatus { Submitted, UnderReview, Approved, Rejected, Paid }

    struct Policy {
        euint64 annualCoverageLimit;  // encrypted
        euint64 deductible;           // encrypted deductible per year
        euint64 usedThisYear;         // encrypted amount used
        euint64 coPayRateBps;         // encrypted copay %
        uint256 renewalDate;
        bool active;
    }

    struct Claim {
        address patient;
        euint64 claimedAmount;        // encrypted patient claim
        euint64 approvedAmount;       // encrypted approved reimbursement
        euint64 patientResponsibility; // encrypted patient's portion
        string treatmentCode;
        uint256 submittedAt;
        ClaimStatus status;
    }

    mapping(address => Policy) private policies;
    mapping(uint256 => Claim) private claims;
    mapping(address => uint256[]) private patientClaims;
    mapping(address => bool) public isInsuranceAdjuster;
    uint256 public claimCount;
    euint64 private _totalClaimsApproved;
    euint64 private _totalClaimsPaid;

    event PolicyIssued(address indexed patient);
    event ClaimSubmitted(uint256 indexed id, address patient);
    event ClaimProcessed(uint256 indexed id, ClaimStatus status);

    modifier onlyAdjuster() {
        require(isInsuranceAdjuster[msg.sender] || msg.sender == owner(), "Not adjuster");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalClaimsApproved = FHE.asEuint64(0);
        _totalClaimsPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalClaimsApproved);
        FHE.allowThis(_totalClaimsPaid);
        isInsuranceAdjuster[msg.sender] = true;
    }

    function addAdjuster(address a) external onlyOwner { isInsuranceAdjuster[a] = true; }

    function issuePolicy(
        address patient,
        externalEuint64 encCoverage, bytes calldata cProof,
        externalEuint64 encDeductible, bytes calldata dProof,
        externalEuint64 encCoPay, bytes calldata pProof,
        uint256 validityDays
    ) external onlyAdjuster {
        euint64 coverage = FHE.fromExternal(encCoverage, cProof);
        euint64 ded = FHE.fromExternal(encDeductible, dProof);
        euint64 copay = FHE.fromExternal(encCoPay, pProof);
        policies[patient] = Policy({
            annualCoverageLimit: coverage, deductible: ded, usedThisYear: FHE.asEuint64(0),
            coPayRateBps: copay, renewalDate: block.timestamp + validityDays * 1 days, active: true
        });
        FHE.allowThis(policies[patient].annualCoverageLimit);
        FHE.allow(policies[patient].annualCoverageLimit, patient);
        FHE.allowThis(policies[patient].deductible);
        FHE.allow(policies[patient].deductible, patient);
        FHE.allowThis(policies[patient].usedThisYear);
        FHE.allow(policies[patient].usedThisYear, patient);
        FHE.allowThis(policies[patient].coPayRateBps);
        emit PolicyIssued(patient);
    }

    function submitClaim(
        externalEuint64 encAmount, bytes calldata proof,
        string calldata treatmentCode
    ) external returns (uint256 claimId) {
        require(policies[msg.sender].active && block.timestamp < policies[msg.sender].renewalDate, "No active policy");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        claimId = claimCount++;
        claims[claimId] = Claim({
            patient: msg.sender, claimedAmount: amount, approvedAmount: FHE.asEuint64(0),
            patientResponsibility: FHE.asEuint64(0), treatmentCode: treatmentCode,
            submittedAt: block.timestamp, status: ClaimStatus.Submitted
        });
        FHE.allowThis(claims[claimId].claimedAmount);
        FHE.allow(claims[claimId].claimedAmount, msg.sender);
        FHE.allowThis(claims[claimId].approvedAmount);
        FHE.allow(claims[claimId].approvedAmount, msg.sender);
        FHE.allowThis(claims[claimId].patientResponsibility);
        FHE.allow(claims[claimId].patientResponsibility, msg.sender);
        patientClaims[msg.sender].push(claimId);
        emit ClaimSubmitted(claimId, msg.sender);
    }

    function processClaim(uint256 claimId) external onlyAdjuster {
        Claim storage c = claims[claimId];
        require(c.status == ClaimStatus.Submitted, "Not pending");
        Policy storage p = policies[c.patient];
        c.status = ClaimStatus.UnderReview;
        // Deductible first
        ebool deductibleMet = FHE.ge(p.usedThisYear, p.deductible);
        euint64 afterDeductible = FHE.select(deductibleMet, c.claimedAmount,
            FHE.select(FHE.ge(c.claimedAmount, p.deductible), FHE.sub(c.claimedAmount, p.deductible), FHE.asEuint64(0)));
        // CoPay
        euint64 copayAmt = FHE.div(FHE.mul(afterDeductible, p.coPayRateBps), 10000);
        euint64 insurancePays = FHE.sub(afterDeductible, copayAmt);
        // Coverage limit check
        euint64 remaining = FHE.sub(p.annualCoverageLimit, p.usedThisYear);
        ebool withinLimit = FHE.le(insurancePays, remaining);
        euint64 approved = FHE.select(withinLimit, insurancePays, remaining);
        c.approvedAmount = approved;
        c.patientResponsibility = FHE.add(copayAmt, FHE.sub(c.claimedAmount, FHE.add(approved, FHE.asEuint64(0))));
        p.usedThisYear = FHE.add(p.usedThisYear, approved);
        c.status = ClaimStatus.Approved;
        _totalClaimsApproved = FHE.add(_totalClaimsApproved, approved);
        FHE.allowThis(c.approvedAmount);
        FHE.allow(c.approvedAmount, c.patient);
        FHE.allowThis(c.patientResponsibility);
        FHE.allow(c.patientResponsibility, c.patient);
        FHE.allowThis(p.usedThisYear);
        FHE.allow(p.usedThisYear, c.patient);
        FHE.allowThis(_totalClaimsApproved);
        emit ClaimProcessed(claimId, ClaimStatus.Approved);
    }

    function payClaim(uint256 claimId) external onlyAdjuster {
        claims[claimId].status = ClaimStatus.Paid;
        _totalClaimsPaid = FHE.add(_totalClaimsPaid, claims[claimId].approvedAmount);
        FHE.allowThis(_totalClaimsPaid);
        FHE.allow(claims[claimId].approvedAmount, claims[claimId].patient);
        emit ClaimProcessed(claimId, ClaimStatus.Paid);
    }

    function allowClaimDetails(uint256 claimId, address viewer) external onlyAdjuster {
        FHE.allow(claims[claimId].claimedAmount, viewer);
        FHE.allow(claims[claimId].approvedAmount, viewer);
        FHE.allow(claims[claimId].patientResponsibility, viewer);
    }
}
