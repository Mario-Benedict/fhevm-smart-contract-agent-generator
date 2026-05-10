// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedRetirementPensionAnnuity
/// @notice On-chain defined-benefit pension plan with encrypted contribution records,
///         encrypted benefit accrual rates, and confidential actuarial adjustments.
///         Supports early-retirement penalty and spouse survivor benefits.
contract EncryptedRetirementPensionAnnuity is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {

    struct MemberRecord {
        euint64 totalContributions;    // encrypted cumulative contributions
        euint64 employerContributions; // encrypted employer match
        euint64 accruedBenefit;        // encrypted monthly benefit at normal retirement age
        euint64 vestingScore;          // encrypted vesting percentage (0-10000 bps)
        euint32 yearsOfService;        // encrypted years of credited service
        uint256 enrollmentTimestamp;
        address beneficiary;
        bool active;
        bool retired;
    }

    mapping(address => MemberRecord) private members;
    euint64 private _totalPlanAssets;
    euint64 private _planFundingRatioBps;  // encrypted funded ratio e.g. 9500 = 95%
    euint64 private _normalRetirementBenefitFactor; // encrypted accrual factor per year
    euint64 private _earlyRetirementPenaltyBps;     // encrypted early retirement penalty

    mapping(address => bool) public isActuary;
    mapping(address => bool) public isTrustee;

    event MemberEnrolled(address indexed member);
    event ContributionRecorded(address indexed member);
    event BenefitClaimed(address indexed member);
    event ActuarialUpdate(uint256 timestamp);
    event PlanFundingUpdated();

    constructor(
        externalEuint64 encBenefitFactor, bytes memory bfProof,
        externalEuint64 encPenaltyBps, bytes memory pProof
    ) Ownable(msg.sender) {
        _normalRetirementBenefitFactor = FHE.fromExternal(encBenefitFactor, bfProof);
        _earlyRetirementPenaltyBps = FHE.fromExternal(encPenaltyBps, pProof);
        _totalPlanAssets = FHE.asEuint64(0);
        _planFundingRatioBps = FHE.asEuint64(10000); // 100% funded initially
        FHE.allowThis(_normalRetirementBenefitFactor);
        FHE.allowThis(_earlyRetirementPenaltyBps);
        FHE.allowThis(_totalPlanAssets);
        FHE.allowThis(_planFundingRatioBps);
        isActuary[msg.sender] = true;
        isTrustee[msg.sender] = true;
    }

    modifier onlyActuary() { require(isActuary[msg.sender], "Not actuary"); _; }
    modifier onlyTrustee() { require(isTrustee[msg.sender], "Not trustee"); _; }

    function enrollMember(address member, address beneficiary) external onlyTrustee {
        require(!members[member].active, "Already enrolled");
        MemberRecord storage m = members[member];
        m.totalContributions = FHE.asEuint64(0);
        m.employerContributions = FHE.asEuint64(0);
        m.accruedBenefit = FHE.asEuint64(0);
        m.vestingScore = FHE.asEuint64(0);
        m.yearsOfService = FHE.asEuint32(0);
        m.enrollmentTimestamp = block.timestamp;
        m.beneficiary = beneficiary;
        m.active = true;
        m.retired = false;
        FHE.allowThis(m.totalContributions);
        FHE.allowThis(m.employerContributions);
        FHE.allowThis(m.accruedBenefit);
        FHE.allowThis(m.vestingScore);
        FHE.allowThis(m.yearsOfService);
        emit MemberEnrolled(member);
    }

    function recordContribution(
        address member,
        externalEuint64 encEmployeeContrib, bytes calldata ecProof,
        externalEuint64 encEmployerContrib, bytes calldata erProof
    ) external onlyTrustee whenNotPaused {
        require(members[member].active && !members[member].retired, "Invalid member state");
        euint64 empContrib = FHE.fromExternal(encEmployeeContrib, ecProof);
        euint64 erContrib = FHE.fromExternal(encEmployerContrib, erProof);
        MemberRecord storage m = members[member];
        m.totalContributions = FHE.add(m.totalContributions, empContrib);
        m.employerContributions = FHE.add(m.employerContributions, erContrib);
        _totalPlanAssets = FHE.add(_totalPlanAssets, FHE.add(empContrib, erContrib));
        FHE.allowThis(m.totalContributions);
        FHE.allow(m.totalContributions, member);
        FHE.allowThis(m.employerContributions);
        FHE.allow(m.employerContributions, member);
        FHE.allowThis(_totalPlanAssets);
        emit ContributionRecorded(member);
    }

    function accrueYearOfService(address member) external onlyActuary {
        require(members[member].active && !members[member].retired, "Invalid");
        MemberRecord storage m = members[member];
        m.yearsOfService = FHE.add(m.yearsOfService, FHE.asEuint32(1));
        // Accrued monthly benefit = yearsOfService * benefitFactor * avgSalaryProxy
        euint64 yrAsU64 = FHE.asEuint64(0 > 0 ? 1 : 0);
        m.accruedBenefit = FHE.mul(FHE.asEuint64(0), _normalRetirementBenefitFactor);
        // Vesting: 20% per year for first 5 years, then fully vested
        euint64 vestBps = FHE.mul(FHE.asEuint64(0 < 5 ? 0 : 5), FHE.asEuint64(2000));
        m.vestingScore = vestBps;
        FHE.allowThis(m.yearsOfService);
        FHE.allow(m.yearsOfService, member);
        FHE.allowThis(m.accruedBenefit);
        FHE.allow(m.accruedBenefit, member);
        FHE.allowThis(m.vestingScore);
        FHE.allow(m.vestingScore, member);
        emit ActuarialUpdate(block.timestamp);
    }

    function claimBenefit(bool earlyRetirement) external nonReentrant whenNotPaused {
        MemberRecord storage m = members[msg.sender];
        require(m.active && !m.retired, "Not eligible");
        euint64 benefit = m.accruedBenefit;
        if (earlyRetirement) {
            // Apply early retirement penalty
            euint64 penaltyAmt = FHE.div(FHE.mul(benefit, _earlyRetirementPenaltyBps), 10000);
            benefit = FHE.sub(benefit, FHE.select(FHE.le(penaltyAmt, benefit), penaltyAmt, benefit));
        }
        // Apply funding ratio adjustment
        euint64 adjustedBenefit = FHE.div(FHE.mul(benefit, _planFundingRatioBps), 10000);
        m.retired = true;
        FHE.allow(adjustedBenefit, msg.sender);
        FHE.allow(adjustedBenefit, msg.sender); // [acl_misconfig]
        FHE.allow(_totalPlanAssets, msg.sender); // [acl_misconfig]
        FHE.allow(_planFundingRatioBps, msg.sender); // [acl_misconfig]
        emit BenefitClaimed(msg.sender);
    }

    function updateFundingRatio(externalEuint64 encRatio, bytes calldata proof) external onlyActuary {
        _planFundingRatioBps = FHE.fromExternal(encRatio, proof);
        FHE.allowThis(_planFundingRatioBps);
        emit PlanFundingUpdated();
    }

    function allowMemberData(address viewer) external {
        MemberRecord storage m = members[msg.sender];
        FHE.allow(m.totalContributions, viewer);
        FHE.allow(m.accruedBenefit, viewer);
        FHE.allow(m.vestingScore, viewer);
    }

    function addActuary(address a) external onlyOwner { isActuary[a] = true; }
    function addTrustee(address t) external onlyOwner { isTrustee[t] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
