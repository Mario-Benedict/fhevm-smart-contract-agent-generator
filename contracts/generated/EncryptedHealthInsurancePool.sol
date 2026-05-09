// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedHealthInsurancePool - Private group health plan with encrypted premium tiers and claims
contract EncryptedHealthInsurancePool is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant ACTUARY_ROLE  = keccak256("ACTUARY_ROLE");
    bytes32 public constant CLAIMS_ROLE   = keccak256("CLAIMS_ROLE");

    struct Member {
        euint8  ageGroup;        // 1=<25, 2=25-40, 3=40-55, 4=55+
        euint8  riskTier;        // 1=low, 2=medium, 3=high
        euint64 annualPremium;
        euint64 totalClaims;
        euint64 poolBalance;     // pre-paid balance in pool
        bool    enrolled;
        uint256 renewalDate;
    }

    struct ClaimRequest {
        address member;
        euint64 claimedAmount;
        euint64 approvedAmount;
        euint8  claimType;       // 1=inpatient, 2=outpatient, 3=dental, 4=vision
        bool    processed;
        bool    approved;
    }

    mapping(address => Member) public members;
    mapping(uint256 => ClaimRequest) public claims;
    euint64 private poolReserves;
    euint64 private totalPremiumsCollected;
    uint256 public memberCount;
    uint256 public claimCount;

    event MemberEnrolled(address indexed member);
    event PremiumPaid(address indexed member);
    event ClaimFiled(uint256 indexed claimId, address indexed member);
    event ClaimProcessed(uint256 indexed claimId, bool approved);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ACTUARY_ROLE, msg.sender);
        _grantRole(CLAIMS_ROLE, msg.sender);
        poolReserves              = FHE.asEuint64(0);
        totalPremiumsCollected    = FHE.asEuint64(0);
        FHE.allowThis(poolReserves);
        FHE.allowThis(totalPremiumsCollected);
    }

    function enrollMember(
        address member,
        externalEuint8 encAge,     bytes calldata ageProof,
        externalEuint8 encRisk,    bytes calldata riskProof,
        externalEuint64 encPremium, bytes calldata premiumProof,
        uint256 coverageDays
    ) external onlyRole(ACTUARY_ROLE) {
        require(!members[member].enrolled, "Already enrolled");
        Member storage m = members[member];
        m.ageGroup      = FHE.fromExternal(encAge,     ageProof);
        m.riskTier      = FHE.fromExternal(encRisk,    riskProof);
        m.annualPremium = FHE.fromExternal(encPremium, premiumProof);
        m.totalClaims   = FHE.asEuint64(0);
        m.poolBalance   = FHE.asEuint64(0);
        m.enrolled      = true;
        m.renewalDate   = block.timestamp + coverageDays * 1 days;
        FHE.allowThis(m.ageGroup); FHE.allowThis(m.riskTier);
        FHE.allowThis(m.annualPremium); FHE.allowThis(m.totalClaims); FHE.allowThis(m.poolBalance);
        FHE.allow(m.annualPremium, member);
        FHE.allow(m.poolBalance, member);
        memberCount++;
        emit MemberEnrolled(member);
    }

    function payPremium(externalEuint64 encAmount, bytes calldata inputProof)
        external nonReentrant
    {
        require(members[msg.sender].enrolled, "Not enrolled");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        members[msg.sender].poolBalance = FHE.add(members[msg.sender].poolBalance, amount);
        poolReserves                    = FHE.add(poolReserves, amount);
        totalPremiumsCollected          = FHE.add(totalPremiumsCollected, amount);
        FHE.allowThis(members[msg.sender].poolBalance); FHE.allowThis(poolReserves); FHE.allowThis(totalPremiumsCollected);
        FHE.allow(members[msg.sender].poolBalance, msg.sender);
        emit PremiumPaid(msg.sender);
    }

    function fileClaim(
        externalEuint64 encAmount, bytes calldata amtProof,
        externalEuint8 encType,   bytes calldata typeProof
    ) external returns (uint256 claimId) {
        require(members[msg.sender].enrolled, "Not enrolled");
        require(block.timestamp <= members[msg.sender].renewalDate, "Coverage expired");
        claimId = claimCount++;
        ClaimRequest storage c = claims[claimId];
        c.member         = msg.sender;
        c.claimedAmount  = FHE.fromExternal(encAmount, amtProof);
        c.claimType      = FHE.fromExternal(encType,   typeProof);
        c.approvedAmount = FHE.asEuint64(0);
        FHE.allowThis(c.claimedAmount); FHE.allowThis(c.approvedAmount); FHE.allowThis(c.claimType);
        // FHE.allow to claims admin skipped (getRoleAdmin returns bytes32, not address)
        emit ClaimFiled(claimId, msg.sender);
    }

    function processClaim(
        uint256 claimId,
        externalEuint64 encApproved, bytes calldata inputProof,
        bool approve
    ) external onlyRole(CLAIMS_ROLE) nonReentrant {
        ClaimRequest storage c = claims[claimId];
        require(!c.processed, "Processed");
        c.processed = true;
        c.approved  = approve;
        if (approve) {
            c.approvedAmount = FHE.fromExternal(encApproved, inputProof);
            members[c.member].totalClaims = FHE.add(members[c.member].totalClaims, c.approvedAmount);
            poolReserves = FHE.sub(poolReserves, c.approvedAmount);
            FHE.allowThis(c.approvedAmount); FHE.allowThis(members[c.member].totalClaims); FHE.allowThis(poolReserves);
            FHE.allow(c.approvedAmount, c.member);
            FHE.allowTransient(c.approvedAmount, c.member);
        }
        emit ClaimProcessed(claimId, approve);
    }
}
