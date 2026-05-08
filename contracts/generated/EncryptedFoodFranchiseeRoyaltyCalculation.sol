// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedFoodFranchiseeRoyaltyCalculation
/// @notice Confidential franchise royalty system with encrypted weekly gross
///         sales, tiered royalty schedules, cooperative advertising fund
///         contributions, and regional performance benchmarking.
contract EncryptedFoodFranchiseeRoyaltyCalculation is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum PerformanceBand { UNDERPERFORMER, MEETS_STANDARD, ABOVE_AVERAGE, TOP_PERFORMER, ELITE }
    enum FeeCategory { ROYALTY, ADVERTISING_FUND, TECHNOLOGY_FEE, TRAINING_FEE, AUDIT_FEE }

    struct FranchiseeProfile {
        euint64 weeklyGrossSales;         // encrypted weekly gross sales
        euint64 monthlyGrossSales;        // encrypted rolling monthly sales
        euint64 ttmGrossSales;            // encrypted trailing 12-month sales
        euint64 royaltyRateBps;           // encrypted royalty rate in bps
        euint64 adFundRateBps;            // encrypted advertising fund rate
        euint64 weeklyRoyaltyDue;         // encrypted current week royalty
        euint64 weeklyAdFundDue;          // encrypted current week ad fund
        euint64 totalRoyaltiesPaid;       // encrypted cumulative royalties
        euint64 totalAdFundContributions; // encrypted cumulative ad fund
        euint64 pendingBalance;           // encrypted outstanding balance
        euint64 salesGrowthRate;          // encrypted YoY growth (signed bps)
        euint64 regionalRankScore;        // encrypted regional ranking score
        PerformanceBand performanceBand;
        uint256 franchiseStartDate;
        uint256 lastReportedWeek;
        bool active;
        bool auditRequired;
    }

    struct RegionalPool {
        euint64 totalAdFundPool;          // encrypted total ad fund in region
        euint64 totalRoyaltyPool;         // encrypted total royalties in region
        euint64 avgWeeklySales;           // encrypted regional average weekly sales
        euint64 topPerformerSales;        // encrypted top performer benchmark
        euint32 franchiseeCount;          // encrypted franchisee count
        euint32 topPerformerCount;        // encrypted elite performer count
    }

    mapping(address => FranchiseeProfile) private franchisees;
    mapping(bytes32 => RegionalPool) private regions;
    mapping(address => bytes32) public franchiseeRegion;
    mapping(address => bool) public authorizedFranchisee;
    mapping(address => bool) public authorizedAuditor;

    euint64 private _totalSystemWideRoyalties;  // encrypted system total royalties
    euint64 private _totalSystemAdFund;         // encrypted system total ad fund
    euint64 private _systemAvgWeeklySales;      // encrypted system-wide average

    event FranchiseeEnrolled(address indexed franchisee, bytes32 indexed regionId);
    event WeeklySalesReported(address indexed franchisee);
    event RoyaltyAssessed(address indexed franchisee, FeeCategory category);
    event PerformanceBandUpdated(address indexed franchisee, PerformanceBand band);
    event AuditTriggered(address indexed franchisee);

    constructor() Ownable(msg.sender) {
        _totalSystemWideRoyalties = FHE.asEuint64(0);
        _totalSystemAdFund = FHE.asEuint64(0);
        _systemAvgWeeklySales = FHE.asEuint64(0);
        FHE.allowThis(_totalSystemWideRoyalties);
        FHE.allowThis(_totalSystemAdFund);
        FHE.allowThis(_systemAvgWeeklySales);
    }

    function enrollFranchisee(
        address franchisee,
        bytes32 regionId,
        externalEuint64 encRoyaltyRate, bytes calldata rrProof,
        externalEuint64 encAdFundRate, bytes calldata afProof
    ) external onlyOwner {
        euint64 royaltyRate = FHE.fromExternal(encRoyaltyRate, rrProof);
        euint64 adFundRate = FHE.fromExternal(encAdFundRate, afProof);

        franchisees[franchisee] = FranchiseeProfile({
            weeklyGrossSales: FHE.asEuint64(0),
            monthlyGrossSales: FHE.asEuint64(0),
            ttmGrossSales: FHE.asEuint64(0),
            royaltyRateBps: royaltyRate,
            adFundRateBps: adFundRate,
            weeklyRoyaltyDue: FHE.asEuint64(0),
            weeklyAdFundDue: FHE.asEuint64(0),
            totalRoyaltiesPaid: FHE.asEuint64(0),
            totalAdFundContributions: FHE.asEuint64(0),
            pendingBalance: FHE.asEuint64(0),
            salesGrowthRate: FHE.asEuint64(0),
            regionalRankScore: FHE.asEuint64(0),
            performanceBand: PerformanceBand.MEETS_STANDARD,
            franchiseStartDate: block.timestamp,
            lastReportedWeek: 0,
            active: true,
            auditRequired: false
        });

        franchiseeRegion[franchisee] = regionId;
        authorizedFranchisee[franchisee] = true;

        FHE.allowThis(royaltyRate); FHE.allow(royaltyRate, franchisee);
        FHE.allowThis(adFundRate); FHE.allow(adFundRate, franchisee);
        FHE.allowThis(franchisees[franchisee].weeklyGrossSales);
        FHE.allow(franchisees[franchisee].weeklyGrossSales, franchisee);
        FHE.allowThis(franchisees[franchisee].weeklyRoyaltyDue);
        FHE.allow(franchisees[franchisee].weeklyRoyaltyDue, franchisee);
        FHE.allowThis(franchisees[franchisee].weeklyAdFundDue);
        FHE.allow(franchisees[franchisee].weeklyAdFundDue, franchisee);
        FHE.allowThis(franchisees[franchisee].totalRoyaltiesPaid);
        FHE.allow(franchisees[franchisee].totalRoyaltiesPaid, franchisee);
        FHE.allowThis(franchisees[franchisee].totalAdFundContributions);
        FHE.allow(franchisees[franchisee].totalAdFundContributions, franchisee);
        FHE.allowThis(franchisees[franchisee].pendingBalance);
        FHE.allow(franchisees[franchisee].pendingBalance, franchisee);
        FHE.allowThis(franchisees[franchisee].monthlyGrossSales);
        FHE.allowThis(franchisees[franchisee].ttmGrossSales);
        FHE.allowThis(franchisees[franchisee].salesGrowthRate);
        FHE.allowThis(franchisees[franchisee].regionalRankScore);

        emit FranchiseeEnrolled(franchisee, regionId);
    }

    function reportWeeklySales(
        externalEuint64 encWeeklySales, bytes calldata wsProof
    ) external nonReentrant {
        require(authorizedFranchisee[msg.sender], "Not franchisee");
        FranchiseeProfile storage f = franchisees[msg.sender];
        require(f.active, "Not active");

        euint64 weeklySales = FHE.fromExternal(encWeeklySales, wsProof);
        f.weeklyGrossSales = weeklySales;
        f.monthlyGrossSales = FHE.add(f.monthlyGrossSales, weeklySales);
        f.ttmGrossSales = FHE.add(f.ttmGrossSales, weeklySales);

        euint64 royalty = FHE.div(FHE.mul(weeklySales, f.royaltyRateBps), FHE.asEuint64(10000));
        euint64 adFund = FHE.div(FHE.mul(weeklySales, f.adFundRateBps), FHE.asEuint64(10000));

        f.weeklyRoyaltyDue = royalty;
        f.weeklyAdFundDue = adFund;
        f.totalRoyaltiesPaid = FHE.add(f.totalRoyaltiesPaid, royalty);
        f.totalAdFundContributions = FHE.add(f.totalAdFundContributions, adFund);
        f.pendingBalance = FHE.add(f.pendingBalance, FHE.add(royalty, adFund));

        _totalSystemWideRoyalties = FHE.add(_totalSystemWideRoyalties, royalty);
        _totalSystemAdFund = FHE.add(_totalSystemAdFund, adFund);

        FHE.allowThis(weeklySales); FHE.allow(weeklySales, msg.sender);
        FHE.allowThis(royalty); FHE.allow(royalty, msg.sender);
        FHE.allowThis(adFund); FHE.allow(adFund, msg.sender);
        FHE.allowThis(f.monthlyGrossSales);
        FHE.allowThis(f.ttmGrossSales);
        FHE.allowThis(f.totalRoyaltiesPaid);
        FHE.allow(f.totalRoyaltiesPaid, msg.sender);
        FHE.allowThis(f.totalAdFundContributions);
        FHE.allow(f.totalAdFundContributions, msg.sender);
        FHE.allowThis(f.pendingBalance);
        FHE.allow(f.pendingBalance, msg.sender);
        FHE.allowThis(_totalSystemWideRoyalties);
        FHE.allowThis(_totalSystemAdFund);

        f.lastReportedWeek = block.timestamp;
        emit WeeklySalesReported(msg.sender);
        emit RoyaltyAssessed(msg.sender, FeeCategory.ROYALTY);
    }

    function updatePerformanceBand(
        address franchisee,
        PerformanceBand newBand,
        externalEuint64 encRankScore, bytes calldata rsProof
    ) external onlyOwner {
        euint64 rankScore = FHE.fromExternal(encRankScore, rsProof);
        franchisees[franchisee].performanceBand = newBand;
        franchisees[franchisee].regionalRankScore = rankScore;
        FHE.allowThis(rankScore); FHE.allow(rankScore, franchisee);
        emit PerformanceBandUpdated(franchisee, newBand);
    }

    function triggerAudit(address franchisee) external onlyOwner {
        franchisees[franchisee].auditRequired = true;
        emit AuditTriggered(franchisee);
    }

    function allowFranchiseeDataView(address franchisee, address viewer) external onlyOwner {
        FHE.allow(franchisees[franchisee].ttmGrossSales, viewer);
        FHE.allow(franchisees[franchisee].totalRoyaltiesPaid, viewer);
        FHE.allow(franchisees[franchisee].totalAdFundContributions, viewer);
    }

    function allowSystemStatsView(address viewer) external onlyOwner {
        FHE.allow(_totalSystemWideRoyalties, viewer);
        FHE.allow(_totalSystemAdFund, viewer);
        FHE.allow(_systemAvgWeeklySales, viewer);
    }
}
