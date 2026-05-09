// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivatePensionFund - Encrypted defined-benefit pension with private salary and accrual data
contract PrivatePensionFund is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct PensionMember {
        euint64 finalSalary;
        euint16 yearsOfService;
        euint64 accruedBenefit;      // lump sum or monthly equivalent
        euint8  benefitFactor;       // e.g. 2 means 2% per year of service
        euint64 employeeContributions;
        euint64 employerContributions;
        uint256 retirementDate;
        bool    retired;
        bool    enrolled;
    }

    mapping(address => PensionMember) public members;
    mapping(address => bool)          public sponsorEmployers;
    euint64 private totalFundAssets;
    euint64 private totalLiabilities;
    uint256 public memberCount;

    event MemberEnrolled(address indexed member);
    event ContributionRecorded(address indexed member, bool isEmployer);
    event BenefitAccrued(address indexed member);
    event RetirementActivated(address indexed member);
    event BenefitPaid(address indexed member);

    constructor() Ownable(msg.sender) {
        totalFundAssets   = FHE.asEuint64(0);
        totalLiabilities  = FHE.asEuint64(0);
        FHE.allowThis(totalFundAssets);
        FHE.allowThis(totalLiabilities);
    }

    function addSponsorEmployer(address employer) external onlyOwner {
        sponsorEmployers[employer] = true;
    }

    function enrollMember(
        address member,
        uint256 retirementDate,
        externalEuint64 encSalary, bytes calldata salaryProof,
        externalEuint8 encFactor, bytes calldata factorProof
    ) external {
        require(sponsorEmployers[msg.sender], "Not sponsor");
        require(!members[member].enrolled,    "Already enrolled");
        PensionMember storage m = members[member];
        m.finalSalary           = FHE.fromExternal(encSalary, salaryProof);
        m.benefitFactor         = FHE.fromExternal(encFactor, factorProof);
        m.yearsOfService        = FHE.asEuint16(0);
        m.accruedBenefit        = FHE.asEuint64(0);
        m.employeeContributions = FHE.asEuint64(0);
        m.employerContributions = FHE.asEuint64(0);
        m.retirementDate        = retirementDate;
        m.enrolled              = true;
        FHE.allowThis(m.finalSalary); FHE.allowThis(m.benefitFactor);
        FHE.allowThis(m.yearsOfService); FHE.allowThis(m.accruedBenefit);
        FHE.allowThis(m.employeeContributions); FHE.allowThis(m.employerContributions);
        FHE.allow(m.finalSalary, member); FHE.allow(m.accruedBenefit, member);
        memberCount++;
        emit MemberEnrolled(member);
    }

    function recordContribution(
        address member, bool isEmployer,
        externalEuint64 encAmount, bytes calldata inputProof
    ) external {
        require(sponsorEmployers[msg.sender] || msg.sender == member, "Unauthorized");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        PensionMember storage m = members[member];
        if (isEmployer) {
            m.employerContributions = FHE.add(m.employerContributions, amount);
            FHE.allowThis(m.employerContributions);
        } else {
            m.employeeContributions = FHE.add(m.employeeContributions, amount);
            FHE.allowThis(m.employeeContributions);
            FHE.allow(m.employeeContributions, member);
        }
        totalFundAssets = FHE.add(totalFundAssets, amount);
        FHE.allowThis(totalFundAssets);
        emit ContributionRecorded(member, isEmployer);
    }

    function accrueYearOfService(address member) external {
        require(sponsorEmployers[msg.sender], "Not sponsor");
        PensionMember storage m = members[member];
        require(m.enrolled && !m.retired, "Invalid state");
        m.yearsOfService = FHE.add(m.yearsOfService, FHE.asEuint16(1));
        // benefit = salary * yearsOfService * benefitFactor / 100
        euint64 benefit = FHE.div(
            FHE.mul(FHE.mul(m.finalSalary, m.yearsOfService), m.benefitFactor),
            100
        );
        m.accruedBenefit = benefit;
        totalLiabilities = FHE.add(totalLiabilities, FHE.asEuint64(1));
        FHE.allowThis(m.yearsOfService); FHE.allowThis(m.accruedBenefit); FHE.allowThis(totalLiabilities);
        FHE.allow(m.accruedBenefit, member);
        emit BenefitAccrued(member);
    }

    function activateRetirement(address member) external {
        require(sponsorEmployers[msg.sender], "Not sponsor");
        require(block.timestamp >= members[member].retirementDate, "Not retirement age");
        members[member].retired = true;
        emit RetirementActivated(member);
    }

    function claimBenefit() external nonReentrant {
        PensionMember storage m = members[msg.sender];
        require(m.retired, "Not retired");
        euint64 payout = FHE.add(m.accruedBenefit, FHE.add(m.employeeContributions, m.employerContributions));
        FHE.allowTransient(payout, msg.sender);
        emit BenefitPaid(msg.sender);
    }
}
