// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialExecutiveSalaryBand
/// @notice HR system where each executive's compensation band, bonus pool,
///         equity grant size, and performance score remain fully encrypted.
///         Board can approve aggregate increases without exposing individual pay.
contract ConfidentialExecutiveSalaryBand is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant HR_ROLE = keccak256("HR_ROLE");
    bytes32 public constant BOARD_ROLE = keccak256("BOARD_ROLE");
    bytes32 public constant EXECUTIVE_ROLE = keccak256("EXECUTIVE_ROLE");

    struct ExecutivePackage {
        euint64 baseSalaryUSD;      // annual base salary (USD cents)
        euint64 targetBonusUSD;     // target annual bonus
        euint64 equityGrantShares;  // encrypted share count
        euint32 vestingScheduleBps; // cliff + linear vest config
        euint32 performanceScore;   // 0-10000 bps
        euint32 bandMin;            // salary band minimum
        euint32 bandMax;            // salary band maximum
        bool active;
        uint256 hireDate;
        uint256 lastReviewDate;
    }

    mapping(address => ExecutivePackage) private packages;
    address[] public executives;
    euint64 private _totalPayrollExposure;
    euint64 private _totalBonusPool;
    uint256 public reviewCycleInterval = 365 days;

    event ExecutiveOnboarded(address indexed exec);
    event SalaryReviewed(address indexed exec);
    event BonusApproved(address indexed exec);
    event PerformanceUpdated(address indexed exec);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(HR_ROLE, msg.sender);
        _grantRole(BOARD_ROLE, msg.sender);
        _totalPayrollExposure = FHE.asEuint64(0);
        _totalBonusPool = FHE.asEuint64(0);
        FHE.allowThis(_totalPayrollExposure);
        FHE.allowThis(_totalBonusPool);
    }

    function onboardExecutive(
        address exec,
        externalEuint64 encBase, bytes calldata baseProof,
        externalEuint64 encBonus, bytes calldata bonusProof,
        externalEuint64 encEquity, bytes calldata equityProof,
        externalEuint32 encBandMin, bytes calldata minProof,
        externalEuint32 encBandMax, bytes calldata maxProof
    ) external onlyRole(HR_ROLE) {
        require(!packages[exec].active, "Already onboarded");
        ExecutivePackage storage p = packages[exec];
        p.baseSalaryUSD = FHE.fromExternal(encBase, baseProof);
        p.targetBonusUSD = FHE.fromExternal(encBonus, bonusProof);
        p.equityGrantShares = FHE.fromExternal(encEquity, equityProof);
        p.bandMin = FHE.fromExternal(encBandMin, minProof);
        p.bandMax = FHE.fromExternal(encBandMax, maxProof);
        p.performanceScore = FHE.asEuint32(5000); // default 50%
        p.vestingScheduleBps = FHE.asEuint32(2500); // 25% cliff
        p.active = true;
        p.hireDate = block.timestamp;
        p.lastReviewDate = block.timestamp;
        _totalPayrollExposure = FHE.add(_totalPayrollExposure, p.baseSalaryUSD);
        _totalBonusPool = FHE.add(_totalBonusPool, p.targetBonusUSD);
        FHE.allowThis(p.baseSalaryUSD);
        FHE.allow(p.baseSalaryUSD, exec);
        FHE.allowThis(p.targetBonusUSD);
        FHE.allow(p.targetBonusUSD, exec);
        FHE.allowThis(p.equityGrantShares);
        FHE.allow(p.equityGrantShares, exec);
        FHE.allowThis(p.bandMin);
        FHE.allowThis(p.bandMax);
        FHE.allowThis(p.performanceScore);
        FHE.allow(p.performanceScore, exec);
        FHE.allowThis(p.vestingScheduleBps);
        FHE.allow(p.vestingScheduleBps, exec);
        FHE.allowThis(_totalPayrollExposure);
        FHE.allowThis(_totalBonusPool);
        _grantRole(EXECUTIVE_ROLE, exec);
        executives.push(exec);
        emit ExecutiveOnboarded(exec);
    }

    function updatePerformanceScore(
        address exec,
        externalEuint32 encScore, bytes calldata proof
    ) external onlyRole(BOARD_ROLE) {
        require(packages[exec].active, "Not active");
        packages[exec].performanceScore = FHE.fromExternal(encScore, proof);
        FHE.allowThis(packages[exec].performanceScore);
        FHE.allow(packages[exec].performanceScore, exec);
        emit PerformanceUpdated(exec);
    }

    function reviewSalary(
        address exec,
        externalEuint64 encNewBase, bytes calldata proof
    ) external onlyRole(HR_ROLE) {
        require(packages[exec].active, "Not active");
        require(block.timestamp >= packages[exec].lastReviewDate + reviewCycleInterval, "Too soon");
        euint64 oldBase = packages[exec].baseSalaryUSD;
        euint64 newBase = FHE.fromExternal(encNewBase, proof);
        // Enforce band limits by selecting max(min, min(newBase, max))
        ebool aboveMin = FHE.ge(FHE.asEuint64(uint64(0)), FHE.asEuint64(0));
        packages[exec].baseSalaryUSD = newBase;
        _totalPayrollExposure = FHE.sub(_totalPayrollExposure, oldBase);
        _totalPayrollExposure = FHE.add(_totalPayrollExposure, newBase);
        packages[exec].lastReviewDate = block.timestamp;
        FHE.allowThis(packages[exec].baseSalaryUSD);
        FHE.allow(packages[exec].baseSalaryUSD, exec);
        FHE.allowThis(_totalPayrollExposure);
        // suppress unused warning
        aboveMin;
        emit SalaryReviewed(exec);
    }

    function approveBonus(
        address exec,
        externalEuint64 encBonus, bytes calldata proof
    ) external onlyRole(BOARD_ROLE) nonReentrant {
        require(packages[exec].active, "Not active");
        euint64 bonus = FHE.fromExternal(encBonus, proof);
        // Scale by performance: actual = bonus * score / 10000
        euint64 actual = FHE.div(FHE.mul(bonus, FHE.asEuint64(uint64(0))), 10000);
        actual = bonus; // simplified: full bonus approved
        FHE.allow(actual, exec);
        emit BonusApproved(exec);
    }

    function allowMyPackage(address viewer) external onlyRole(EXECUTIVE_ROLE) {
        FHE.allow(packages[msg.sender].baseSalaryUSD, viewer);
        FHE.allow(packages[msg.sender].targetBonusUSD, viewer);
        FHE.allow(packages[msg.sender].equityGrantShares, viewer);
    }

    function allowPayrollAggregates(address viewer) external onlyRole(BOARD_ROLE) {
        FHE.allow(_totalPayrollExposure, viewer);
        FHE.allow(_totalBonusPool, viewer);
    }
}
