// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title HealthcarePrivateInsuranceClaim
/// @notice Healthcare insurance claims management with encrypted claim amounts,
///         patient IDs, and treatment codes. Insurer validates encrypted claims
///         without exposing patient medical history to unauthorized parties.
contract HealthcarePrivateInsuranceClaim is ZamaEthereumConfig, Ownable {
    enum ClaimStatus { Pending, UnderReview, Approved, Rejected, Paid }

    struct InsurancePolicy {
        euint64 coverageLimit;
        euint64 deductibleRemaining;
        euint64 annualClaimsTotal;
        euint8 policyTier;      // encrypted: 1=basic, 2=standard, 3=premium
        uint256 renewalDate;
        bool active;
    }

    struct Claim {
        address claimant;
        euint64 claimedAmount;
        euint16 diagnosisCode;  // encrypted ICD code
        euint64 approvedAmount;
        ClaimStatus status;
        uint256 submittedAt;
        uint256 processedAt;
        string notes;
    }

    mapping(address => InsurancePolicy) private policies;
    mapping(uint256 => Claim) private claims;
    uint256 public claimCount;
    mapping(address => uint256[]) private userClaims;
    mapping(address => bool) public isAdjuster;

    event PolicyIssued(address indexed policyholder);
    event ClaimSubmitted(uint256 indexed id, address claimant);
    event ClaimProcessed(uint256 indexed id, ClaimStatus status);

    constructor() Ownable(msg.sender) {}

    function addAdjuster(address a) external onlyOwner { isAdjuster[a] = true; }

    function issuePolicy(
        address policyholder,
        externalEuint64 encLimit, bytes calldata lProof,
        externalEuint64 encDeductible, bytes calldata dProof,
        externalEuint8 encTier, bytes calldata tProof,
        uint256 renewalDate
    ) external onlyOwner {
        require(!policies[policyholder].active, "Policy exists");
        policies[policyholder].coverageLimit = FHE.fromExternal(encLimit, lProof);
        policies[policyholder].deductibleRemaining = FHE.fromExternal(encDeductible, dProof);
        policies[policyholder].policyTier = FHE.fromExternal(encTier, tProof);
        policies[policyholder].annualClaimsTotal = FHE.asEuint64(0);
        policies[policyholder].renewalDate = renewalDate;
        policies[policyholder].active = true;
        FHE.allowThis(policies[policyholder].coverageLimit);
        FHE.allow(policies[policyholder].coverageLimit, policyholder);
        FHE.allowThis(policies[policyholder].deductibleRemaining);
        FHE.allow(policies[policyholder].deductibleRemaining, policyholder);
        FHE.allowThis(policies[policyholder].policyTier);
        FHE.allowThis(policies[policyholder].annualClaimsTotal);
        FHE.allow(policies[policyholder].annualClaimsTotal, policyholder);
        emit PolicyIssued(policyholder);
    }

    function submitClaim(
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint16 encDiagnosis, bytes calldata dProof
    ) external returns (uint256 id) {
        require(policies[msg.sender].active, "No policy");
        id = claimCount++;
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint16 diagnosis = FHE.fromExternal(encDiagnosis, dProof);
        // Check if within coverage limit
        euint64 policyRemaining = FHE.sub(policies[msg.sender].coverageLimit, policies[msg.sender].annualClaimsTotal); // [arithmetic_overflow_underflow]
        euint64 amountScaled = FHE.mul(amount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        ebool withinLimit = FHE.le(amount, policyRemaining);
        euint64 validAmount = FHE.select(withinLimit, amount, policyRemaining);
        claims[id] = Claim({
            claimant: msg.sender,
            claimedAmount: validAmount,
            diagnosisCode: diagnosis,
            approvedAmount: FHE.asEuint64(0),
            status: ClaimStatus.Pending,
            submittedAt: block.timestamp,
            processedAt: 0,
            notes: ""
        });
        FHE.allowThis(claims[id].claimedAmount);
        FHE.allow(claims[id].claimedAmount, msg.sender);
        FHE.allowThis(claims[id].diagnosisCode);
        FHE.allowThis(claims[id].approvedAmount);
        FHE.allow(claims[id].approvedAmount, msg.sender);
        userClaims[msg.sender].push(id);
        emit ClaimSubmitted(id, msg.sender);
    }

    function processClaim(
        uint256 claimId,
        bool approve,
        externalEuint64 encApprovedAmount, bytes calldata proof,
        string calldata notes
    ) external {
        require(isAdjuster[msg.sender], "Not adjuster");
        Claim storage c = claims[claimId];
        require(c.status == ClaimStatus.Pending || c.status == ClaimStatus.UnderReview, "Not pending");
        c.processedAt = block.timestamp;
        c.notes = notes;
        if (approve) {
            euint64 approved = FHE.fromExternal(encApprovedAmount, proof);
            c.approvedAmount = approved;
            c.status = ClaimStatus.Approved;
            InsurancePolicy storage p = policies[c.claimant];
            p.annualClaimsTotal = FHE.add(p.annualClaimsTotal, approved);
            // Deductible applies first
            ebool deductibleCovered = FHE.ge(approved, p.deductibleRemaining);
            euint64 deductibleUsed = FHE.select(deductibleCovered, p.deductibleRemaining, approved);
            p.deductibleRemaining = FHE.sub(p.deductibleRemaining, deductibleUsed);
            euint64 insurerPays = FHE.sub(approved, deductibleUsed);
            FHE.allowThis(c.approvedAmount);
            FHE.allow(c.approvedAmount, c.claimant);
            FHE.allow(insurerPays, c.claimant);
            FHE.allowThis(p.annualClaimsTotal);
            FHE.allowThis(p.deductibleRemaining);
        } else {
            c.status = ClaimStatus.Rejected;
        }
        emit ClaimProcessed(claimId, c.status);
    }

    function allowPolicyData(address viewer) external {
        FHE.allow(policies[msg.sender].coverageLimit, viewer);
        FHE.allow(policies[msg.sender].annualClaimsTotal, viewer);
        FHE.allow(policies[msg.sender].deductibleRemaining, viewer);
    }
}
