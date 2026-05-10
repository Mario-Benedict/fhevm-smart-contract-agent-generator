// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiEncryptedInsurancePremium
/// @notice DeFi insurance protocol where risk scores and premiums are encrypted.
///         Underwriters set encrypted premium pricing models. Policyholders submit
///         encrypted claims; the protocol validates against encrypted coverage limits.
contract DeFiEncryptedInsurancePremium is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum RiskCategory { Low, Medium, High, Critical }

    struct Policy {
        euint64 coverageAmount;
        euint64 premiumPaid;
        euint8 riskScore;       // encrypted 0-100
        RiskCategory category;
        uint256 startDate;
        uint256 endDate;
        bool active;
        bool claimed;
    }

    struct Claim {
        euint64 claimAmount;
        euint8 verificationScore; // encrypted verifier assessment
        bool processed;
        bool approved;
    }

    mapping(address => Policy) private policies;
    mapping(uint256 => Claim) private claims;
    uint256 public claimCount;
    euint64 private _totalPremiums;
    euint64 private _totalCoverage;
    euint64 private _claimsReserve;
    euint64 private _maxClaimRatioBps; // encrypted max payout as % of premium pool

    event PolicyIssued(address indexed policyholder);
    event ClaimFiled(uint256 indexed claimId, address policyholder);
    event ClaimProcessed(uint256 indexed claimId, bool approved);

    constructor(
        externalEuint64 encMaxClaimRatio, bytes memory proof
    ) Ownable(msg.sender) {
        _maxClaimRatioBps = FHE.fromExternal(encMaxClaimRatio, proof);
        _totalPremiums = FHE.asEuint64(0);
        _totalCoverage = FHE.asEuint64(0);
        _claimsReserve = FHE.asEuint64(0);
        FHE.allowThis(_maxClaimRatioBps);
        FHE.allowThis(_totalPremiums);
        FHE.allowThis(_totalCoverage);
        FHE.allowThis(_claimsReserve);
    }

    function issuePolicy(
        address policyholder,
        externalEuint64 encCoverage, bytes calldata cProof,
        externalEuint64 encPremium, bytes calldata pProof,
        externalEuint8 encRisk, bytes calldata rProof,
        RiskCategory category,
        uint256 durationDays
    ) external onlyOwner {
        require(!policies[policyholder].active, "Policy exists");
        euint64 coverage = FHE.fromExternal(encCoverage, cProof);
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        euint8 risk = FHE.fromExternal(encRisk, rProof);
        policies[policyholder] = Policy({
            coverageAmount: coverage, premiumPaid: premium, riskScore: risk,
            category: category, startDate: block.timestamp,
            endDate: block.timestamp + durationDays * 1 days,
            active: true, claimed: false
        });
        _totalPremiums = FHE.add(_totalPremiums, premium);
        _totalCoverage = FHE.add(_totalCoverage, coverage);
        _claimsReserve = FHE.add(_claimsReserve, FHE.div(FHE.mul(premium, 7000), 10000));
        FHE.allowThis(policies[policyholder].coverageAmount);
        FHE.allow(policies[policyholder].coverageAmount, policyholder);
        FHE.allowThis(policies[policyholder].premiumPaid);
        FHE.allowThis(policies[policyholder].riskScore);
        FHE.allowThis(_totalPremiums);
        FHE.allowThis(_totalCoverage);
        FHE.allowThis(_claimsReserve);
        emit PolicyIssued(policyholder);
    }

    function fileClaim(externalEuint64 encClaimAmount, bytes calldata proof) external returns (uint256 id) {
        Policy storage p = policies[msg.sender];
        require(p.active && !p.claimed, "Cannot claim");
        require(block.timestamp <= p.endDate, "Policy expired");
        id = claimCount++;
        euint64 claimAmount = FHE.fromExternal(encClaimAmount, proof);
        ebool withinCoverage = FHE.le(claimAmount, p.coverageAmount);
        euint64 validClaim = FHE.select(withinCoverage, claimAmount, p.coverageAmount);
        claims[id] = Claim({ claimAmount: validClaim, verificationScore: FHE.asEuint8(0), processed: false, approved: false });
        FHE.allowThis(claims[id].claimAmount);
        FHE.allow(claims[id].claimAmount, msg.sender);
        FHE.allowThis(claims[id].verificationScore);
        emit ClaimFiled(id, msg.sender);
    }

    function processClaim(uint256 id, address policyholder, externalEuint8 encVerScore, bytes calldata proof) external onlyOwner {
        Claim storage c = claims[id];
        require(!c.processed, "Already processed");
        c.processed = true;
        c.verificationScore = FHE.fromExternal(encVerScore, proof);
        FHE.allowThis(c.verificationScore);
        ebool highScore = FHE.ge(c.verificationScore, FHE.asEuint8(60));
        ebool hasFunds = FHE.ge(_claimsReserve, c.claimAmount);
        ebool approved = FHE.and(highScore, hasFunds);
        c.approved = FHE.isInitialized(approved);
        if (c.approved) {
            ebool _safeSub109 = FHE.ge(_claimsReserve, c.claimAmount);
            _claimsReserve = FHE.select(_safeSub109, FHE.sub(_claimsReserve, c.claimAmount), FHE.asEuint64(0));
            policies[policyholder].claimed = true;
            FHE.allow(c.claimAmount, policyholder);
            FHE.allowThis(_claimsReserve);
        }
        emit ClaimProcessed(id, c.approved);
    }

    function allowPolicyData(address viewer) external {
        FHE.allow(policies[msg.sender].coverageAmount, viewer);
        FHE.allow(policies[msg.sender].premiumPaid, viewer);
    }
}
