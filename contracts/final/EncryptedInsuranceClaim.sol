// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedInsuranceClaim - Private insurance claim processing with encrypted payouts
contract EncryptedInsuranceClaim is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant ADJUSTER_ROLE = keccak256("ADJUSTER_ROLE");
    bytes32 public constant UNDERWRITER_ROLE = keccak256("UNDERWRITER_ROLE");

    enum ClaimStatus { Submitted, UnderReview, Approved, Rejected, Paid }

    struct Policy {
        address holder;
        euint64 coverageAmount;
        euint64 premium;
        euint8 policyType;     // 1=health, 2=auto, 3=home, 4=life
        uint256 expiryDate;
        bool active;
    }

    struct Claim {
        uint256 policyId;
        address claimant;
        euint64 claimedAmount;
        euint64 approvedAmount;
        euint8 severityScore;
        ClaimStatus status;
        string evidenceHash;
        uint256 submittedAt;
        address adjuster;
    }

    mapping(uint256 => Policy) public policies;
    mapping(uint256 => Claim) public claims;
    mapping(address => uint256[]) public holderPolicies;
    mapping(address => uint256[]) public holderClaims;
    uint256 public policyCount;
    uint256 public claimCount;
    euint64 private totalLiability;
    euint64 private totalPremiumsCollected;

    event PolicyIssued(uint256 indexed policyId, address indexed holder);
    event ClaimSubmitted(uint256 indexed claimId, uint256 indexed policyId);
    event ClaimAdjudicated(uint256 indexed claimId, ClaimStatus status);
    event ClaimPaid(uint256 indexed claimId, address indexed claimant);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADJUSTER_ROLE, msg.sender);
        _grantRole(UNDERWRITER_ROLE, msg.sender);
        totalLiability = FHE.asEuint64(0);
        totalPremiumsCollected = FHE.asEuint64(0);
        FHE.allowThis(totalLiability);
        FHE.allowThis(totalPremiumsCollected);
    }

    function issuePolicy(
        address holder,
        externalEuint64 encCoverage,
        bytes calldata coverageProof,
        externalEuint64 encPremium,
        bytes calldata premiumProof,
        externalEuint8 encType,
        bytes calldata typeProof,
        uint256 durationDays
    ) external onlyRole(UNDERWRITER_ROLE) returns (uint256 policyId) {
        policyId = policyCount++;
        Policy storage p = policies[policyId];
        p.holder = holder;
        p.coverageAmount = FHE.fromExternal(encCoverage, coverageProof);
        p.premium = FHE.fromExternal(encPremium, premiumProof);
        p.policyType = FHE.fromExternal(encType, typeProof);
        p.expiryDate = block.timestamp + durationDays * 1 days;
        p.active = true;
        FHE.allowThis(p.coverageAmount);
        FHE.allowThis(p.premium);
        FHE.allowThis(p.policyType);
        FHE.allow(p.coverageAmount, holder);
        FHE.allow(p.premium, holder);
        totalLiability = FHE.add(totalLiability, p.coverageAmount);
        totalPremiumsCollected = FHE.add(totalPremiumsCollected, p.premium);
        FHE.allowThis(totalLiability);
        FHE.allowThis(totalPremiumsCollected);
        holderPolicies[holder].push(policyId);
        emit PolicyIssued(policyId, holder);
    }

    function submitClaim(
        uint256 policyId,
        externalEuint64 encAmount,
        bytes calldata amountProof,
        string calldata evidenceHash
    ) external returns (uint256 claimId) {
        Policy storage p = policies[policyId];
        require(p.holder == msg.sender, "Not policy holder");
        require(p.active && block.timestamp <= p.expiryDate, "Policy expired");

        claimId = claimCount++;
        Claim storage c = claims[claimId];
        c.policyId = policyId;
        c.claimant = msg.sender;
        c.claimedAmount = FHE.fromExternal(encAmount, amountProof);
        c.approvedAmount = FHE.asEuint64(0);
        c.severityScore = FHE.asEuint8(0);
        c.status = ClaimStatus.Submitted;
        c.evidenceHash = evidenceHash;
        c.submittedAt = block.timestamp;
        FHE.allowThis(c.claimedAmount);
        FHE.allowThis(c.approvedAmount);
        FHE.allowThis(c.severityScore);
        FHE.allow(c.claimedAmount, msg.sender);
        // FHE.allow to adjuster admin skipped (getRoleAdmin returns bytes32, not address)
        holderClaims[msg.sender].push(claimId);
        emit ClaimSubmitted(claimId, policyId);
    }

    function adjudicateClaim(
        uint256 claimId,
        externalEuint64 encApproved,
        bytes calldata approvedProof,
        externalEuint8 encSeverity,
        bytes calldata severityProof,
        bool approve
    ) external onlyRole(ADJUSTER_ROLE) {
        Claim storage c = claims[claimId];
        require(c.status == ClaimStatus.Submitted || c.status == ClaimStatus.UnderReview, "Invalid state");
        c.approvedAmount = FHE.fromExternal(encApproved, approvedProof);
        c.severityScore = FHE.fromExternal(encSeverity, severityProof);
        c.adjuster = msg.sender;
        c.status = approve ? ClaimStatus.Approved : ClaimStatus.Rejected;
        FHE.allowThis(c.approvedAmount);
        FHE.allowThis(c.severityScore);
        FHE.allow(c.approvedAmount, c.claimant);
        FHE.allow(c.severityScore, c.claimant);
        emit ClaimAdjudicated(claimId, c.status);
    }

    function payClaim(uint256 claimId) external nonReentrant onlyRole(UNDERWRITER_ROLE) {
        Claim storage c = claims[claimId];
        require(c.status == ClaimStatus.Approved, "Not approved");
        c.status = ClaimStatus.Paid;
        FHE.allow(c.approvedAmount, c.claimant); // [acl_misconfig]
        FHE.allow(totalLiability, msg.sender); // [acl_misconfig]
        FHE.allow(totalPremiumsCollected, msg.sender); // [acl_misconfig]
        emit ClaimPaid(claimId, c.claimant);
    }
}
