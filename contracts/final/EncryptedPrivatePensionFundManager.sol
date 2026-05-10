// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivatePensionFundManager
/// @notice Encrypted pension fund management: hidden contribution amounts,
///         private fund allocation strategies, confidential member benefit
///         entitlements, and encrypted actuarial liability calculations.
contract EncryptedPrivatePensionFundManager is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum PensionTier { Basic, Standard, Enhanced, Executive }
    enum AssetClass { Equity, FixedIncome, Alternatives, Cash, Infrastructure }

    struct PensionMember {
        address memberWallet;
        PensionTier tier;
        euint64 accumulatedBenefitUSD; // encrypted benefit balance
        euint64 employerContribYTD;    // encrypted employer YTD
        euint64 employeeContribYTD;    // encrypted employee YTD
        euint64 projectedRetirementBenefit; // encrypted projection
        euint16 yearsOfService;        // encrypted service years
        bool retired;
        uint256 enrolledAt;
    }

    struct FundAllocation {
        AssetClass assetClass;
        euint64 allocatedUSD;          // encrypted allocation
        euint64 currentValueUSD;       // encrypted current value
        euint64 targetBps;             // encrypted target allocation
        euint64 returnRateBps;         // encrypted return rate
    }

    mapping(uint256 => PensionMember) private members;
    mapping(address => uint256) private memberIdByWallet;
    mapping(uint256 => FundAllocation) private allocations;
    mapping(address => bool) public isPensionAdministrator;

    uint256 public memberCount;
    uint256 public allocationCount;
    euint64 private _totalFundValueUSD;
    euint64 private _totalContributionsUSD;
    euint64 private _totalLiabilityUSD;

    event MemberEnrolled(uint256 indexed id, PensionTier tier);
    event ContributionRecorded(uint256 indexed memberId, uint256 recordedAt);
    event BenefitPaid(uint256 indexed memberId, uint256 paidAt);

    modifier onlyPensionAdministrator() {
        require(isPensionAdministrator[msg.sender] || msg.sender == owner(), "Not pension administrator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalFundValueUSD = FHE.asEuint64(0);
        _totalContributionsUSD = FHE.asEuint64(0);
        _totalLiabilityUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalFundValueUSD); FHE.allowThis(_totalContributionsUSD); FHE.allowThis(_totalLiabilityUSD);
        isPensionAdministrator[msg.sender] = true;
    }

    function addPensionAdministrator(address pa) external onlyOwner { isPensionAdministrator[pa] = true; }

    function enrollMember(
        address memberWallet, PensionTier tier,
        externalEuint16 encYearsService, bytes calldata ysProof,
        externalEuint64 encProjectedBenefit, bytes calldata pbProof
    ) external onlyPensionAdministrator returns (uint256 id) {
        euint16 yearsService = FHE.fromExternal(encYearsService, ysProof);
        euint64 projBenefit  = FHE.fromExternal(encProjectedBenefit, pbProof);
        id = memberCount++;
        memberIdByWallet[memberWallet] = id;
        members[id].memberWallet = memberWallet;
        members[id].tier = tier;
        members[id].accumulatedBenefitUSD = FHE.asEuint64(0);
        members[id].employerContribYTD = FHE.asEuint64(0);
        members[id].employeeContribYTD = FHE.asEuint64(0);
        members[id].projectedRetirementBenefit = projBenefit;
        members[id].yearsOfService = yearsService;
        members[id].retired = false;
        members[id].enrolledAt = block.timestamp;
        _totalLiabilityUSD = FHE.add(_totalLiabilityUSD, projBenefit);
        FHE.allowThis(members[id].accumulatedBenefitUSD); FHE.allow(members[id].accumulatedBenefitUSD, memberWallet); // [acl_misconfig]
        FHE.allow(_totalFundValueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalContributionsUSD, msg.sender); // [acl_misconfig]
        FHE.allowThis(members[id].employerContribYTD); FHE.allow(members[id].employerContribYTD, memberWallet);
        FHE.allowThis(members[id].employeeContribYTD); FHE.allow(members[id].employeeContribYTD, memberWallet);
        FHE.allowThis(members[id].projectedRetirementBenefit); FHE.allow(members[id].projectedRetirementBenefit, memberWallet);
        FHE.allowThis(members[id].yearsOfService); FHE.allow(members[id].yearsOfService, memberWallet);
        FHE.allowThis(_totalLiabilityUSD);
        emit MemberEnrolled(id, tier);
    }

    function recordContribution(
        uint256 memberId,
        externalEuint64 encEmployer, bytes calldata emProof,
        externalEuint64 encEmployee, bytes calldata eeProof
    ) external onlyPensionAdministrator {
        PensionMember storage m = members[memberId];
        euint64 employer = FHE.fromExternal(encEmployer, emProof);
        euint64 employee = FHE.fromExternal(encEmployee, eeProof);
        euint64 total = FHE.add(employer, employee);
        m.employerContribYTD = FHE.add(m.employerContribYTD, employer);
        m.employeeContribYTD = FHE.add(m.employeeContribYTD, employee);
        m.accumulatedBenefitUSD = FHE.add(m.accumulatedBenefitUSD, total);
        _totalContributionsUSD = FHE.add(_totalContributionsUSD, total);
        _totalFundValueUSD = FHE.add(_totalFundValueUSD, total);
        FHE.allowThis(m.employerContribYTD); FHE.allow(m.employerContribYTD, m.memberWallet);
        FHE.allowThis(m.employeeContribYTD); FHE.allow(m.employeeContribYTD, m.memberWallet);
        FHE.allowThis(m.accumulatedBenefitUSD); FHE.allow(m.accumulatedBenefitUSD, m.memberWallet);
        FHE.allowThis(_totalContributionsUSD); FHE.allowThis(_totalFundValueUSD);
        emit ContributionRecorded(memberId, block.timestamp);
    }

    function payRetirementBenefit(uint256 memberId, externalEuint64 encPayment, bytes calldata proof) external onlyPensionAdministrator nonReentrant {
        PensionMember storage m = members[memberId];
        require(!m.retired, "Not retired status");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        ebool sufficient = FHE.ge(m.accumulatedBenefitUSD, payment);
        euint64 effPayment = FHE.select(sufficient, payment, m.accumulatedBenefitUSD);
        m.accumulatedBenefitUSD = FHE.sub(m.accumulatedBenefitUSD, effPayment);
        _totalFundValueUSD = FHE.sub(_totalFundValueUSD, effPayment);
        FHE.allowThis(m.accumulatedBenefitUSD); FHE.allow(m.accumulatedBenefitUSD, m.memberWallet);
        FHE.allow(effPayment, m.memberWallet);
        FHE.allowThis(_totalFundValueUSD);
        emit BenefitPaid(memberId, block.timestamp);
    }

    function allowFundStats(address viewer) external onlyOwner {
        FHE.allow(_totalFundValueUSD, viewer); FHE.allow(_totalContributionsUSD, viewer); FHE.allow(_totalLiabilityUSD, viewer);
    }
    function getMemberBalance(address w) external view returns (euint64) { return members[memberIdByWallet[w]].accumulatedBenefitUSD; }
}
