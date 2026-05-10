// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateHedgeFundLiquidityStressTest
/// @notice Confidential hedge fund liquidity stress test and capital allocation platform.
///         Encrypted NAV, hidden redemption queues, private stress scenario exposures,
///         and confidential margin call thresholds.
contract PrivateHedgeFundLiquidityStressTest is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum StressScenario { BaseCase, MildStress, ModerateStress, SevereStress, TailRisk }
    enum RedemptionStatus { Pending, Gated, Fulfilled, Deferred }

    struct FundProfile {
        address fundManager;
        string fundName;
        euint64 navUSD;                // encrypted NAV
        euint64 liquidAssetRatioUSD;   // encrypted liquid assets
        euint64 gateLevelBps;          // encrypted gate threshold bps
        euint64 redemptionQueueUSD;    // encrypted total pending redemptions
        euint32 lockupDays;            // encrypted lockup period
        bool gateActive;
    }

    struct RedemptionRequest {
        uint256 fundId;
        address investor;
        euint64 requestedAmountUSD;    // encrypted redemption amount
        euint64 approvedAmountUSD;     // encrypted approved amount
        RedemptionStatus status;
        uint256 submittedAt;
    }

    struct StressTestResult {
        uint256 fundId;
        StressScenario scenario;
        euint64 projectedNavUSD;       // encrypted projected NAV under scenario
        euint64 liquidityShortfallUSD; // encrypted liquidity gap
        euint16 survivalProbabilityBps;// encrypted survival probability
        uint256 testedAt;
    }

    mapping(uint256 => FundProfile) private funds;
    mapping(uint256 => RedemptionRequest) private redemptions;
    mapping(uint256 => StressTestResult) private stressResults;
    mapping(address => bool) public isRiskOfficer;

    uint256 public fundCount;
    uint256 public redemptionCount;
    uint256 public stressResultCount;
    euint64 private _totalAUMUSD;

    event FundRegistered(uint256 indexed id, string fundName);
    event RedemptionSubmitted(uint256 indexed rId, uint256 fundId);
    event RedemptionFulfilled(uint256 indexed rId);
    event StressTestCompleted(uint256 indexed resultId, uint256 fundId, StressScenario scenario);

    modifier onlyRiskOfficer() {
        require(isRiskOfficer[msg.sender] || msg.sender == owner(), "Not risk officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAUMUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalAUMUSD);
        isRiskOfficer[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addRiskOfficer(address r) external onlyOwner { isRiskOfficer[r] = true; }

    function registerFund(
        string calldata fundName,
        externalEuint64 encNAV, bytes calldata navProof,
        externalEuint64 encLiquidAssets, bytes calldata laProof,
        externalEuint64 encGateLevel, bytes calldata glProof,
        externalEuint32 encLockup, bytes calldata lockProof
    ) external whenNotPaused returns (uint256 id) {
        euint64 nav = FHE.fromExternal(encNAV, navProof);
        euint64 navWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 navExposure = FHE.sub(navWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint64 liquid = FHE.fromExternal(encLiquidAssets, laProof);
        euint64 gate = FHE.fromExternal(encGateLevel, glProof);
        euint32 lockup = FHE.fromExternal(encLockup, lockProof);
        id = fundCount++;
        funds[id] = FundProfile({
            fundManager: msg.sender, fundName: fundName, navUSD: nav,
            liquidAssetRatioUSD: liquid, gateLevelBps: gate,
            redemptionQueueUSD: FHE.asEuint64(0), lockupDays: lockup, gateActive: false
        });
        _totalAUMUSD = FHE.add(_totalAUMUSD, nav);
        FHE.allowThis(funds[id].navUSD); FHE.allow(funds[id].navUSD, msg.sender);
        FHE.allowThis(funds[id].liquidAssetRatioUSD); FHE.allow(funds[id].liquidAssetRatioUSD, msg.sender);
        FHE.allowThis(funds[id].gateLevelBps);
        FHE.allowThis(funds[id].redemptionQueueUSD); FHE.allow(funds[id].redemptionQueueUSD, msg.sender);
        FHE.allowThis(funds[id].lockupDays);
        FHE.allowThis(_totalAUMUSD);
        emit FundRegistered(id, fundName);
    }

    function submitRedemption(
        uint256 fundId,
        externalEuint64 encAmount, bytes calldata proof
    ) external whenNotPaused returns (uint256 rId) {
        FundProfile storage f = funds[fundId];
        euint64 amt = FHE.fromExternal(encAmount, proof);
        rId = redemptionCount++;
        redemptions[rId] = RedemptionRequest({
            fundId: fundId, investor: msg.sender, requestedAmountUSD: amt,
            approvedAmountUSD: FHE.asEuint64(0), status: RedemptionStatus.Pending,
            submittedAt: block.timestamp
        });
        f.redemptionQueueUSD = FHE.add(f.redemptionQueueUSD, amt);
        // Check if gate should be active (queue > gate level): branchless
        ebool gateTriggered = FHE.ge(f.redemptionQueueUSD, f.gateLevelBps);
        FHE.allowThis(redemptions[rId].requestedAmountUSD); FHE.allow(redemptions[rId].requestedAmountUSD, msg.sender);
        FHE.allowThis(redemptions[rId].approvedAmountUSD);
        FHE.allowThis(f.redemptionQueueUSD); FHE.allow(f.redemptionQueueUSD, f.fundManager);
        FHE.allowThis(gateTriggered);
        if (FHE.isInitialized(gateTriggered)) f.gateActive = true;
        emit RedemptionSubmitted(rId, fundId);
    }

    function fulfillRedemption(
        uint256 rId,
        externalEuint64 encApprovedAmt, bytes calldata proof
    ) external onlyRiskOfficer nonReentrant {
        RedemptionRequest storage r = redemptions[rId];
        require(r.status == RedemptionStatus.Pending, "Not pending");
        FundProfile storage f = funds[r.fundId];
        euint64 approved = FHE.fromExternal(encApprovedAmt, proof);
        // Cap approved at requested
        ebool withinRequest = FHE.le(approved, r.requestedAmountUSD);
        euint64 finalApproved = FHE.select(withinRequest, approved, r.requestedAmountUSD);
        r.approvedAmountUSD = finalApproved;
        r.status = RedemptionStatus.Fulfilled;
        f.navUSD = FHE.sub(f.navUSD, finalApproved);
        f.redemptionQueueUSD = FHE.sub(f.redemptionQueueUSD, r.requestedAmountUSD);
        _totalAUMUSD = FHE.sub(_totalAUMUSD, finalApproved);
        FHE.allowThis(r.approvedAmountUSD); FHE.allow(r.approvedAmountUSD, r.investor); FHE.allow(r.approvedAmountUSD, f.fundManager);
        FHE.allowThis(f.navUSD); FHE.allow(f.navUSD, f.fundManager);
        FHE.allowThis(f.redemptionQueueUSD); FHE.allow(f.redemptionQueueUSD, f.fundManager);
        FHE.allowThis(_totalAUMUSD);
        emit RedemptionFulfilled(rId);
    }

    function runStressTest(
        uint256 fundId,
        StressScenario scenario,
        externalEuint64 encProjNav, bytes calldata navProof,
        externalEuint64 encShortfall, bytes calldata sfProof,
        externalEuint16 encSurvival, bytes calldata survProof
    ) external onlyRiskOfficer returns (uint256 resultId) {
        euint64 projNav = FHE.fromExternal(encProjNav, navProof);
        euint64 shortfall = FHE.fromExternal(encShortfall, sfProof);
        euint16 survival = FHE.fromExternal(encSurvival, survProof);
        resultId = stressResultCount++;
        stressResults[resultId] = StressTestResult({
            fundId: fundId, scenario: scenario, projectedNavUSD: projNav,
            liquidityShortfallUSD: shortfall, survivalProbabilityBps: survival,
            testedAt: block.timestamp
        });
        FundProfile storage f = funds[fundId];
        FHE.allowThis(stressResults[resultId].projectedNavUSD); FHE.allow(stressResults[resultId].projectedNavUSD, f.fundManager);
        FHE.allowThis(stressResults[resultId].liquidityShortfallUSD); FHE.allow(stressResults[resultId].liquidityShortfallUSD, f.fundManager);
        FHE.allowThis(stressResults[resultId].survivalProbabilityBps); FHE.allow(stressResults[resultId].survivalProbabilityBps, f.fundManager);
        emit StressTestCompleted(resultId, fundId, scenario);
    }

    function allowAUMView(address viewer) external onlyOwner {
        FHE.allow(_totalAUMUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalAUMUSD, msg.sender); // [acl_misconfig]
    }
}
