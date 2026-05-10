// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAgingPopulationPensionFund
/// @notice Encrypted pension fund management: hidden individual benefit accruals,
///         confidential actuarial liability estimates, private funding ratio calculations,
///         and encrypted contribution rates for employer/employee splits.
contract PrivateAgingPopulationPensionFund is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum PlanType { DefinedBenefit, DefinedContribution, HybridCash, MultiEmployer }
    enum MemberStatus { Active, Deferred, InPayment, Deceased }

    struct PensionPlan {
        string planName;
        PlanType planType;
        address actuary;
        euint64 totalAssetsUSD;        // encrypted total assets
        euint64 presentValueLiabilityUSD; // encrypted PV of liabilities
        euint64 fundingRatioBps;       // encrypted funding ratio
        euint64 annualContributionsUSD;// encrypted annual contributions
        euint16 discountRateBps;       // encrypted actuarial discount rate
        uint256 valuationDate;
    }

    struct PensionMember {
        uint256 planId;
        address member;
        MemberStatus status;
        euint64 accruedBenefitUSD;     // encrypted accrued benefit
        euint64 employerContribUSD;    // encrypted employer contributions
        euint64 employeeContribUSD;    // encrypted employee contributions
        euint32 serviceYears;          // encrypted years of service
        uint256 memberSince;
    }

    mapping(uint256 => PensionPlan) private plans;
    mapping(uint256 => PensionMember) private members;
    mapping(address => bool) public isActuary;

    uint256 public planCount;
    uint256 public memberCount;
    euint64 private _totalAUMUSD;

    event PlanCreated(uint256 indexed id, string planName, PlanType planType);
    event MemberEnrolled(uint256 indexed memberId, uint256 planId);
    event ValuationUpdated(uint256 indexed planId, uint256 valuationDate);

    modifier onlyActuary() {
        require(isActuary[msg.sender] || msg.sender == owner(), "Not actuary");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAUMUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalAUMUSD);
        isActuary[msg.sender] = true;
    }

    function addActuary(address a) external onlyOwner { isActuary[a] = true; }

    function createPlan(
        string calldata planName, PlanType planType,
        externalEuint64 encAssets, bytes calldata aProof,
        externalEuint64 encLiability, bytes calldata lProof,
        externalEuint16 encDiscountRate, bytes calldata drProof
    ) external onlyActuary returns (uint256 id) {
        euint64 assets = FHE.fromExternal(encAssets, aProof);
        euint64 liability = FHE.fromExternal(encLiability, lProof);
        euint16 discountRate = FHE.fromExternal(encDiscountRate, drProof);
        euint64 fundingRatio = FHE.div(FHE.mul(assets, 10000), 1); // proxy
        id = planCount++;
        plans[id].planName = planName;
        plans[id].planType = planType;
        plans[id].actuary = msg.sender;
        plans[id].totalAssetsUSD = assets;
        plans[id].presentValueLiabilityUSD = liability;
        plans[id].fundingRatioBps = fundingRatio;
        plans[id].annualContributionsUSD = FHE.asEuint64(0);
        plans[id].discountRateBps = discountRate;
        plans[id].valuationDate = block.timestamp;
        _totalAUMUSD = FHE.add(_totalAUMUSD, assets);
        FHE.allowThis(plans[id].totalAssetsUSD); FHE.allow(plans[id].totalAssetsUSD, msg.sender);
        FHE.allowThis(plans[id].presentValueLiabilityUSD); FHE.allow(plans[id].presentValueLiabilityUSD, msg.sender);
        FHE.allowThis(plans[id].fundingRatioBps); FHE.allow(plans[id].fundingRatioBps, msg.sender);
        FHE.allowThis(plans[id].annualContributionsUSD); FHE.allow(plans[id].annualContributionsUSD, msg.sender);
        FHE.allowThis(plans[id].discountRateBps);
        FHE.allowThis(_totalAUMUSD);
        emit PlanCreated(id, planName, planType);
    }

    function enrollMember(
        uint256 planId, address member,
        externalEuint32 encServiceYears, bytes calldata syProof
    ) external onlyActuary returns (uint256 memberId) {
        euint32 serviceYears = FHE.fromExternal(encServiceYears, syProof);
        memberId = memberCount++;
        members[memberId] = PensionMember({
            planId: planId, member: member, status: MemberStatus.Active,
            accruedBenefitUSD: FHE.asEuint64(0), employerContribUSD: FHE.asEuint64(0),
            employeeContribUSD: FHE.asEuint64(0), serviceYears: serviceYears, memberSince: block.timestamp
        });
        FHE.allowThis(members[memberId].accruedBenefitUSD); FHE.allow(members[memberId].accruedBenefitUSD, member);
        FHE.allowThis(members[memberId].employerContribUSD); FHE.allow(members[memberId].employerContribUSD, member);
        FHE.allowThis(members[memberId].employeeContribUSD); FHE.allow(members[memberId].employeeContribUSD, member);
        FHE.allowThis(members[memberId].serviceYears); FHE.allow(members[memberId].serviceYears, member);
        emit MemberEnrolled(memberId, planId);
    }

    function recordContributions(
        uint256 memberId,
        externalEuint64 encEmployer, bytes calldata erProof,
        externalEuint64 encEmployee, bytes calldata eeProof
    ) external nonReentrant {
        PensionMember storage m = members[memberId];
        require(msg.sender == m.member || isActuary[msg.sender], "Not authorized");
        euint64 erContrib = FHE.fromExternal(encEmployer, erProof);
        euint64 eeContrib = FHE.fromExternal(encEmployee, eeProof);
        m.employerContribUSD = FHE.add(m.employerContribUSD, erContrib);
        m.employeeContribUSD = FHE.add(m.employeeContribUSD, eeContrib);
        PensionPlan storage p = plans[m.planId];
        p.totalAssetsUSD = FHE.add(p.totalAssetsUSD, FHE.add(erContrib, eeContrib));
        p.annualContributionsUSD = FHE.add(p.annualContributionsUSD, FHE.add(erContrib, eeContrib));
        FHE.allowThis(m.employerContribUSD); FHE.allow(m.employerContribUSD, m.member);
        FHE.allowThis(m.employeeContribUSD); FHE.allow(m.employeeContribUSD, m.member);
        FHE.allowThis(p.totalAssetsUSD); FHE.allow(p.totalAssetsUSD, p.actuary);
        FHE.allowThis(p.annualContributionsUSD); FHE.allow(p.annualContributionsUSD, p.actuary);
    }

    function updateActuarialValuation(
        uint256 planId,
        externalEuint64 encNewAssets, bytes calldata naProof,
        externalEuint64 encNewLiability, bytes calldata nlProof
    ) external onlyActuary {
        PensionPlan storage p = plans[planId];
        p.totalAssetsUSD = FHE.fromExternal(encNewAssets, naProof);
        p.presentValueLiabilityUSD = FHE.fromExternal(encNewLiability, nlProof);
        p.valuationDate = block.timestamp;
        FHE.allowThis(p.totalAssetsUSD); FHE.allow(p.totalAssetsUSD, msg.sender);
        FHE.allowThis(p.presentValueLiabilityUSD); FHE.allow(p.presentValueLiabilityUSD, msg.sender);
        emit ValuationUpdated(planId, block.timestamp);
    }

    function allowAUMView(address viewer) external onlyOwner {
        FHE.allow(_totalAUMUSD, viewer);
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