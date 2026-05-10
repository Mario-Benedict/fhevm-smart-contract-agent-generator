// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivatePensionFundAllocation
/// @notice Defined benefit pension fund: encrypted actuarial liabilities, encrypted asset allocation,
///         encrypted member benefit accruals, and confidential funding status ratios.
contract PrivatePensionFundAllocation is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct PensionMember {
        address member;
        euint64 accrualRateBps;         // encrypted annual accrual rate
        euint64 salaryUSD;              // encrypted current salary
        euint64 projectedBenefitUSD;    // encrypted projected annual benefit
        euint64 accumulatedBenefitUSD;  // encrypted accumulated benefit to date
        euint64 employerContributions;  // encrypted employer contributions
        euint64 employeeContributions;  // encrypted employee contributions
        uint256 yearsOfService;
        uint256 retirementDate;
        bool active;
        bool retired;
    }

    struct AssetAllocation {
        euint64 equitiesUSD;       // encrypted equities
        euint64 fixedIncomeUSD;    // encrypted bonds/fixed income
        euint64 alternativesUSD;   // encrypted alternatives (PE, RE, infra)
        euint64 cashUSD;           // encrypted cash
        euint64 totalAUMUSD;       // encrypted total AUM
        euint64 fundingRatioBps;   // encrypted funding ratio (assets/liabilities * 10000)
        euint64 liabilitiesUSD;    // encrypted actuarial liabilities
        uint256 lastRebalanced;
    }

    mapping(address => PensionMember) private members;
    AssetAllocation private allocation;
    mapping(address => bool) public isActuary;
    mapping(address => bool) public isTrustee;
    euint64 private _totalMemberLiabilities;

    event MemberEnrolled(address indexed member);
    event BenefitAccrued(address indexed member);
    event ContributionReceived(address indexed member);
    event FundRebalanced();
    event MemberRetired(address indexed member);

    constructor(
        externalEuint64 encEquities, bytes memory eqProof,
        externalEuint64 encFixed, bytes memory fProof,
        externalEuint64 encCash, bytes memory cProof
    ) Ownable(msg.sender) {
        euint64 eq = FHE.fromExternal(encEquities, eqProof);
        euint64 fi = FHE.fromExternal(encFixed, fProof);
        euint64 cash = FHE.fromExternal(encCash, cProof);
        euint64 total = FHE.add(FHE.add(eq, fi), cash);
        allocation = AssetAllocation({
            equitiesUSD: eq, fixedIncomeUSD: fi, alternativesUSD: FHE.asEuint64(0),
            cashUSD: cash, totalAUMUSD: total, fundingRatioBps: FHE.asEuint64(0),
            liabilitiesUSD: FHE.asEuint64(0), lastRebalanced: block.timestamp
        });
        _totalMemberLiabilities = FHE.asEuint64(0);
        FHE.allowThis(allocation.equitiesUSD);
        FHE.allowThis(allocation.fixedIncomeUSD);
        FHE.allowThis(allocation.cashUSD);
        FHE.allowThis(allocation.totalAUMUSD);
        FHE.allowThis(allocation.fundingRatioBps);
        FHE.allowThis(allocation.liabilitiesUSD);
        FHE.allowThis(_totalMemberLiabilities);
        isActuary[msg.sender] = true;
        isTrustee[msg.sender] = true;
    }

    function addActuary(address a) external onlyOwner { isActuary[a] = true; }
    function addTrustee(address t) external onlyOwner { isTrustee[t] = true; }

    function enrollMember(
        address member,
        externalEuint64 encSalary, bytes calldata sProof,
        externalEuint64 encAccrualRate, bytes calldata arProof,
        uint256 yearsOfService, uint256 retirementDate
    ) external {
        require(isTrustee[msg.sender], "Not trustee");
        euint64 salary = FHE.fromExternal(encSalary, sProof);
        euint64 accrualRate = FHE.fromExternal(encAccrualRate, arProof);
        members[member].member = member;
        members[member].accrualRateBps = accrualRate;
        members[member].salaryUSD = salary;
        members[member].projectedBenefitUSD = FHE.asEuint64(0);
        members[member].accumulatedBenefitUSD = FHE.asEuint64(0);
        members[member].employerContributions = FHE.asEuint64(0);
        members[member].employeeContributions = FHE.asEuint64(0);
        members[member].yearsOfService = yearsOfService;
        members[member].retirementDate = retirementDate;
        members[member].active = true;
        members[member].retired = false;
        FHE.allowThis(members[member].salaryUSD);
        FHE.allowThis(members[member].accrualRateBps);
        FHE.allowThis(members[member].projectedBenefitUSD);
        FHE.allowThis(members[member].accumulatedBenefitUSD);
        FHE.allowThis(members[member].employerContributions);
        FHE.allowThis(members[member].employeeContributions);
        FHE.allow(members[member].accumulatedBenefitUSD, member); // [acl_misconfig]
        FHE.allow(_totalMemberLiabilities, msg.sender); // [acl_misconfig]
        FHE.allow(members[member].projectedBenefitUSD, member);
        emit MemberEnrolled(member);
    }

    function accrueAnnualBenefit(address member) external {
        require(isActuary[msg.sender], "Not actuary");
        PensionMember storage m = members[member];
        require(m.active && !m.retired, "Not active");
        // Annual accrual = salary * accrualRate / 10000
        euint64 annualAccrual = FHE.div(FHE.mul(m.salaryUSD, m.accrualRateBps), 10000);
        m.accumulatedBenefitUSD = FHE.add(m.accumulatedBenefitUSD, annualAccrual);
        // Projected = accumulated + (yearsToRetirement * annualAccrual)
        m.projectedBenefitUSD = FHE.add(m.accumulatedBenefitUSD, FHE.mul(annualAccrual, FHE.asEuint64(10)));
        m.yearsOfService++;
        _totalMemberLiabilities = FHE.add(_totalMemberLiabilities, annualAccrual);
        FHE.allowThis(m.accumulatedBenefitUSD);
        FHE.allow(m.accumulatedBenefitUSD, member);
        FHE.allowThis(m.projectedBenefitUSD);
        FHE.allow(m.projectedBenefitUSD, member);
        FHE.allowThis(_totalMemberLiabilities);
        emit BenefitAccrued(member);
    }

    function receiveContributions(
        address member,
        externalEuint64 encEmployer, bytes calldata erProof,
        externalEuint64 encEmployee, bytes calldata eeProof
    ) external nonReentrant {
        euint64 employer = FHE.fromExternal(encEmployer, erProof);
        euint64 employee = FHE.fromExternal(encEmployee, eeProof);
        PensionMember storage m = members[member];
        m.employerContributions = FHE.add(m.employerContributions, employer);
        m.employeeContributions = FHE.add(m.employeeContributions, employee);
        euint64 total = FHE.add(employer, employee);
        allocation.cashUSD = FHE.add(allocation.cashUSD, total);
        allocation.totalAUMUSD = FHE.add(allocation.totalAUMUSD, total);
        FHE.allowThis(m.employerContributions);
        FHE.allow(m.employerContributions, member);
        FHE.allowThis(m.employeeContributions);
        FHE.allow(m.employeeContributions, member);
        FHE.allowThis(allocation.cashUSD);
        FHE.allowThis(allocation.totalAUMUSD);
        emit ContributionReceived(member);
    }

    function updateFundingRatio(uint64 liabilitiesPlaintext) external {
        require(isActuary[msg.sender], "Not actuary");
        allocation.liabilitiesUSD = _totalMemberLiabilities;
        ebool hasLiabilities = FHE.gt(allocation.liabilitiesUSD, FHE.asEuint64(0));
        allocation.fundingRatioBps = FHE.select(hasLiabilities,
            liabilitiesPlaintext > 0 ? FHE.div(FHE.mul(allocation.totalAUMUSD, 10000), liabilitiesPlaintext) : FHE.asEuint64(0),
            FHE.asEuint64(0));
        FHE.allowThis(allocation.fundingRatioBps);
        FHE.allow(allocation.fundingRatioBps, owner());
        FHE.allowThis(allocation.liabilitiesUSD);
    }

    function rebalanceFund(
        externalEuint64 encEquities, bytes calldata eqProof,
        externalEuint64 encFixed, bytes calldata fProof,
        externalEuint64 encAlternatives, bytes calldata altProof,
        externalEuint64 encCash, bytes calldata cProof
    ) external {
        require(isTrustee[msg.sender], "Not trustee");
        allocation.equitiesUSD = FHE.fromExternal(encEquities, eqProof);
        allocation.fixedIncomeUSD = FHE.fromExternal(encFixed, fProof);
        allocation.alternativesUSD = FHE.fromExternal(encAlternatives, altProof);
        allocation.cashUSD = FHE.fromExternal(encCash, cProof);
        allocation.totalAUMUSD = FHE.add(
            FHE.add(allocation.equitiesUSD, allocation.fixedIncomeUSD),
            FHE.add(allocation.alternativesUSD, allocation.cashUSD));
        allocation.lastRebalanced = block.timestamp;
        FHE.allowThis(allocation.equitiesUSD);
        FHE.allowThis(allocation.fixedIncomeUSD);
        FHE.allowThis(allocation.alternativesUSD);
        FHE.allowThis(allocation.cashUSD);
        FHE.allowThis(allocation.totalAUMUSD);
        emit FundRebalanced();
    }

    function retireMember(address member) external {
        require(isTrustee[msg.sender], "Not trustee");
        members[member].retired = true;
        members[member].active = false;
        FHE.allow(members[member].accumulatedBenefitUSD, member); // [acl_misconfig]
        emit MemberRetired(member);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}