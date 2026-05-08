// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateFoodBeverageFranchiseRoyalty
/// @notice Encrypted food franchise royalty management: hidden franchisee gross sales,
///         confidential royalty rates per brand tier, private marketing levy collections,
///         and encrypted compliance audit scoring for franchise renewal decisions.
contract PrivateFoodBeverageFranchiseRoyalty is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum BrandTier { Premium, Standard, Economy, Ghost }
    enum RenewalStatus { Eligible, Conditional, NotEligible }

    struct FranchiseUnit {
        address franchisee;
        string unitCode;
        BrandTier tier;
        string territory;
        euint64 weeklyGrossSalesUSD;   // encrypted weekly gross
        euint64 royaltyRateBps;        // encrypted royalty rate
        euint64 marketingLevyBps;      // encrypted marketing contribution bps
        euint64 totalRoyaltiesPaidUSD; // encrypted accumulated royalties
        euint64 totalLevyPaidUSD;      // encrypted accumulated levy
        euint16 auditScorePoints;      // encrypted compliance score (0-1000)
        RenewalStatus renewalStatus;
        uint256 openedAt;
        uint256 termEndDate;
    }

    mapping(uint256 => FranchiseUnit) private units;
    mapping(address => bool) public isFranchiseAuditor;

    uint256 public unitCount;
    euint64 private _totalNetworkRoyaltiesUSD;
    euint64 private _totalNetworkLeviesUSD;

    event UnitRegistered(uint256 indexed id, string unitCode, BrandTier tier);
    event WeeklySalesSettled(uint256 indexed unitId, uint256 settledAt);
    event RenewalDecision(uint256 indexed unitId, RenewalStatus status);

    modifier onlyFranchiseAuditor() {
        require(isFranchiseAuditor[msg.sender] || msg.sender == owner(), "Not franchise auditor");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalNetworkRoyaltiesUSD = FHE.asEuint64(0);
        _totalNetworkLeviesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalNetworkRoyaltiesUSD);
        FHE.allowThis(_totalNetworkLeviesUSD);
        isFranchiseAuditor[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addAuditor(address a) external onlyOwner { isFranchiseAuditor[a] = true; }

    function registerFranchiseUnit(
        address franchisee, string calldata unitCode, BrandTier tier, string calldata territory,
        externalEuint64 encRoyaltyRate, bytes calldata rrProof,
        externalEuint64 encLevyBps, bytes calldata levyProof,
        uint256 termDays
    ) external onlyOwner whenNotPaused returns (uint256 id) {
        euint64 royaltyRate = FHE.fromExternal(encRoyaltyRate, rrProof);
        euint64 levyBps = FHE.fromExternal(encLevyBps, levyProof);
        id = unitCount++;
        units[id] = FranchiseUnit({
            franchisee: franchisee, unitCode: unitCode, tier: tier, territory: territory,
            weeklyGrossSalesUSD: FHE.asEuint64(0), royaltyRateBps: royaltyRate,
            marketingLevyBps: levyBps, totalRoyaltiesPaidUSD: FHE.asEuint64(0),
            totalLevyPaidUSD: FHE.asEuint64(0), auditScorePoints: FHE.asEuint16(0),
            renewalStatus: RenewalStatus.Eligible, openedAt: block.timestamp,
            termEndDate: block.timestamp + termDays * 1 days
        });
        FHE.allowThis(units[id].royaltyRateBps); FHE.allow(units[id].royaltyRateBps, franchisee);
        FHE.allowThis(units[id].marketingLevyBps); FHE.allow(units[id].marketingLevyBps, franchisee);
        FHE.allowThis(units[id].weeklyGrossSalesUSD);
        FHE.allowThis(units[id].totalRoyaltiesPaidUSD); FHE.allow(units[id].totalRoyaltiesPaidUSD, franchisee);
        FHE.allowThis(units[id].totalLevyPaidUSD); FHE.allow(units[id].totalLevyPaidUSD, franchisee);
        FHE.allowThis(units[id].auditScorePoints); FHE.allow(units[id].auditScorePoints, franchisee);
        emit UnitRegistered(id, unitCode, tier);
    }

    function settleWeeklySales(
        uint256 unitId,
        externalEuint64 encWeeklyGross, bytes calldata proof
    ) external nonReentrant {
        FranchiseUnit storage u = units[unitId];
        require(msg.sender == u.franchisee || msg.sender == owner(), "Not authorized");
        euint64 weeklyGross = FHE.fromExternal(encWeeklyGross, proof);
        u.weeklyGrossSalesUSD = weeklyGross;
        euint64 royalty = FHE.div(weeklyGross, 20); // 5% fixed rate (plaintext divisor)
        euint64 levy = FHE.div(weeklyGross, 50);    // 2% fixed levy (plaintext divisor)
        u.totalRoyaltiesPaidUSD = FHE.add(u.totalRoyaltiesPaidUSD, royalty);
        u.totalLevyPaidUSD = FHE.add(u.totalLevyPaidUSD, levy);
        _totalNetworkRoyaltiesUSD = FHE.add(_totalNetworkRoyaltiesUSD, royalty);
        _totalNetworkLeviesUSD = FHE.add(_totalNetworkLeviesUSD, levy);
        FHE.allowThis(u.weeklyGrossSalesUSD); FHE.allow(u.weeklyGrossSalesUSD, owner());
        FHE.allowThis(u.totalRoyaltiesPaidUSD); FHE.allow(u.totalRoyaltiesPaidUSD, u.franchisee);
        FHE.allowThis(u.totalLevyPaidUSD); FHE.allow(u.totalLevyPaidUSD, u.franchisee);
        FHE.allowThis(_totalNetworkRoyaltiesUSD);
        FHE.allowThis(_totalNetworkLeviesUSD);
        emit WeeklySalesSettled(unitId, block.timestamp);
    }

    function conductFranchiseAudit(
        uint256 unitId,
        externalEuint16 encAuditScore, bytes calldata proof,
        RenewalStatus renewalDecision
    ) external onlyFranchiseAuditor {
        FranchiseUnit storage u = units[unitId];
        u.auditScorePoints = FHE.fromExternal(encAuditScore, proof);
        u.renewalStatus = renewalDecision;
        FHE.allowThis(u.auditScorePoints); FHE.allow(u.auditScorePoints, u.franchisee);
        emit RenewalDecision(unitId, renewalDecision);
    }

    function allowNetworkStats(address viewer) external onlyOwner {
        FHE.allow(_totalNetworkRoyaltiesUSD, viewer);
        FHE.allow(_totalNetworkLeviesUSD, viewer);
    }
}
