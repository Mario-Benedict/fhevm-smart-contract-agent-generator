// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialMilitaryPensionFundManager
/// @notice Pension fund for military veterans where pension amounts, service
///         classifications, disability ratings, and survivor benefit elections
///         remain encrypted to protect sensitive military personnel data.
contract ConfidentialMilitaryPensionFundManager is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Veteran {
        euint64 monthlyPensionUSD;    // base monthly pension
        euint64 disabilityAdjUSD;     // disability supplement
        euint64 survivorBenefitBps;   // % of pension to survivor
        euint32 serviceYears;         // years of service
        euint32 disabilityRatingBps;  // 0-10000 = 0-100%
        euint32 securityClearance;    // 1=public, 2=secret, 3=top secret
        address survivor;
        bool enrolled;
        bool deceased;
        uint256 enrollDate;
        uint256 retirementDate;
    }

    mapping(address => Veteran) private veterans;
    address[] public veteranList;

    euint64 private _totalFundAssets;
    euint64 private _monthlyObligations;
    euint64 private _totalPaidToDate;
    uint256 public lastDistributionDate;
    uint256 public distributionInterval = 30 days;

    event VeteranEnrolled(address indexed veteran);
    event PensionDistributed(address indexed veteran);
    event SurvivorBenefitActivated(address indexed veteran, address indexed survivor);
    event DisabilityRatingUpdated(address indexed veteran);

    constructor(externalEuint64 encInitialAssets, bytes memory proof) Ownable(msg.sender) {
        _totalFundAssets = FHE.fromExternal(encInitialAssets, proof);
        _monthlyObligations = FHE.asEuint64(0);
        _totalPaidToDate = FHE.asEuint64(0);
        lastDistributionDate = block.timestamp;
        FHE.allowThis(_totalFundAssets);
        FHE.allowThis(_monthlyObligations);
        FHE.allowThis(_totalPaidToDate);
    }

    function enrollVeteran(
        address veteran,
        externalEuint64 encBasePension, bytes calldata baseProof,
        externalEuint64 encSurvivorBps, bytes calldata survProof,
        externalEuint32 encServiceYears, bytes calldata yearsProof,
        externalEuint32 encClearance, bytes calldata clearanceProof,
        address survivor,
        uint256 retirementDate
    ) external onlyOwner {
        require(!veterans[veteran].enrolled, "Already enrolled");
        Veteran storage v = veterans[veteran];
        v.monthlyPensionUSD = FHE.fromExternal(encBasePension, baseProof);
        v.survivorBenefitBps = FHE.fromExternal(encSurvivorBps, survProof);
        v.serviceYears = FHE.fromExternal(encServiceYears, yearsProof);
        v.securityClearance = FHE.fromExternal(encClearance, clearanceProof);
        v.disabilityRatingBps = FHE.asEuint32(0);
        v.disabilityAdjUSD = FHE.asEuint64(0);
        v.survivor = survivor;
        v.enrolled = true;
        v.enrollDate = block.timestamp;
        v.retirementDate = retirementDate;
        _monthlyObligations = FHE.add(_monthlyObligations, v.monthlyPensionUSD);
        FHE.allowThis(v.monthlyPensionUSD);
        FHE.allow(v.monthlyPensionUSD, veteran);
        FHE.allowThis(v.survivorBenefitBps);
        FHE.allow(v.survivorBenefitBps, veteran);
        FHE.allowThis(v.serviceYears);
        FHE.allow(v.serviceYears, veteran);
        FHE.allowThis(v.securityClearance);
        FHE.allowThis(v.disabilityRatingBps);
        FHE.allowThis(v.disabilityAdjUSD);
        FHE.allowThis(_monthlyObligations);
        veteranList.push(veteran);
        emit VeteranEnrolled(veteran);
    }

    function updateDisabilityRating(
        address veteran,
        externalEuint32 encRating, bytes calldata ratingProof,
        externalEuint64 encAdjUSD, bytes calldata adjProof
    ) external onlyOwner {
        require(veterans[veteran].enrolled, "Not enrolled");
        veterans[veteran].disabilityRatingBps = FHE.fromExternal(encRating, ratingProof);
        euint64 oldAdj = veterans[veteran].disabilityAdjUSD;
        veterans[veteran].disabilityAdjUSD = FHE.fromExternal(encAdjUSD, adjProof);
        _monthlyObligations = FHE.sub(_monthlyObligations, oldAdj);
        _monthlyObligations = FHE.add(_monthlyObligations, veterans[veteran].disabilityAdjUSD);
        FHE.allowThis(veterans[veteran].disabilityRatingBps);
        FHE.allow(veterans[veteran].disabilityRatingBps, veteran);
        FHE.allowThis(veterans[veteran].disabilityAdjUSD);
        FHE.allow(veterans[veteran].disabilityAdjUSD, veteran);
        FHE.allowThis(_monthlyObligations);
        emit DisabilityRatingUpdated(veteran);
    }

    function distributePension(address veteran) external onlyOwner nonReentrant {
        require(veterans[veteran].enrolled && !veterans[veteran].deceased, "Not active");
        require(block.timestamp >= lastDistributionDate + distributionInterval, "Too soon");
        Veteran storage v = veterans[veteran];
        euint64 total = FHE.add(v.monthlyPensionUSD, v.disabilityAdjUSD);
        ebool fundSufficient = FHE.le(total, _totalFundAssets);
        euint64 actual = FHE.select(fundSufficient, total, _totalFundAssets);
        _totalFundAssets = FHE.sub(_totalFundAssets, actual);
        _totalPaidToDate = FHE.add(_totalPaidToDate, actual);
        FHE.allowThis(_totalFundAssets);
        FHE.allowThis(_totalPaidToDate);
        FHE.allow(actual, veteran);
        emit PensionDistributed(veteran);
    }

    function activateSurvivorBenefit(address veteran) external onlyOwner {
        Veteran storage v = veterans[veteran];
        require(v.enrolled && !v.deceased, "Not active");
        v.deceased = true;
        // Survivor gets a % of pension
        euint64 survivorAmount = FHE.div(FHE.mul(v.monthlyPensionUSD, 0), 10000);
        // Simplified: survivor gets 55%
        survivorAmount = FHE.div(FHE.mul(v.monthlyPensionUSD, 55), 100);
        _monthlyObligations = FHE.sub(_monthlyObligations, v.monthlyPensionUSD);
        _monthlyObligations = FHE.add(_monthlyObligations, survivorAmount);
        FHE.allowThis(_monthlyObligations);
        FHE.allow(survivorAmount, v.survivor);
        emit SurvivorBenefitActivated(veteran, v.survivor);
    }

    function fundFund(externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _totalFundAssets = FHE.add(_totalFundAssets, amount);
        FHE.allowThis(_totalFundAssets);
    }

    function allowMyPensionData(address viewer) external {
        require(veterans[msg.sender].enrolled, "Not veteran");
        FHE.allow(veterans[msg.sender].monthlyPensionUSD, viewer);
        FHE.allow(veterans[msg.sender].disabilityAdjUSD, viewer);
        FHE.allow(veterans[msg.sender].serviceYears, viewer);
    }

    function allowFundMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalFundAssets, viewer);
        FHE.allow(_monthlyObligations, viewer);
        FHE.allow(_totalPaidToDate, viewer);
    }
}
