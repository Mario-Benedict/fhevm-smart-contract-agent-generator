// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateArtificialIntelligenceModelLicensing
/// @notice Encrypted AI model IP licensing: hidden model accuracy benchmarks, confidential
///         inference pricing per API call, private training dataset valuation, and encrypted
///         fine-tuning royalty calculations.
contract PrivateArtificialIntelligenceModelLicensing is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ModelType { LLM, VisionModel, SpeechRecognition, RecommendationEngine, FraudDetection }
    enum LicenseType { APIAccess, OnPremise, FineTuning, FullSource }

    struct AIModelLicense {
        address modelDeveloper;
        address licensee;
        ModelType modelType;
        LicenseType licenseType;
        string modelRef;
        euint64 annualLicenseFeeUSD;   // encrypted license fee
        euint64 perCallPriceUSD;       // encrypted per-inference price
        euint64 totalCallsUsed;        // encrypted usage count
        euint64 trainingDataValueUSD;  // encrypted training data value
        euint16 accuracyBenchmarkBps;  // encrypted accuracy score
        euint64 fineTuningRoyaltyBps;  // encrypted fine-tuning royalty bps
        euint64 totalRevenueAccruedUSD;// encrypted total revenue
        bool active;
        uint256 licenseStart;
        uint256 licenseEnd;
    }

    mapping(uint256 => AIModelLicense) private licenses;
    mapping(address => bool) public isAIAuditor;

    uint256 public licenseCount;
    euint64 private _totalAILicenseRevenueUSD;

    event LicenseCreated(uint256 indexed id, ModelType modelType, LicenseType licenseType);
    event UsageRecorded(uint256 indexed licenseId, uint256 recordedAt);
    event LicenseRevoked(uint256 indexed licenseId);

    modifier onlyAIAuditor() {
        require(isAIAuditor[msg.sender] || msg.sender == owner(), "Not AI auditor");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAILicenseRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalAILicenseRevenueUSD);
        isAIAuditor[msg.sender] = true;
    }

    function addAIAuditor(address a) external onlyOwner { isAIAuditor[a] = true; }

    function createLicense(
        address licensee, ModelType modelType, LicenseType licenseType, string calldata modelRef,
        externalEuint64 encAnnualFee, bytes calldata afProof,
        externalEuint64 encPerCall, bytes calldata pcProof,
        externalEuint64 encTrainingValue, bytes calldata tvProof,
        externalEuint16 encAccuracy, bytes calldata accProof,
        externalEuint64 encFTRoyalty, bytes calldata ftrProof,
        uint256 durationDays
    ) external returns (uint256 id) {
        euint64 annualFee = FHE.fromExternal(encAnnualFee, afProof);
        euint64 perCall = FHE.fromExternal(encPerCall, pcProof);
        euint64 trainingValue = FHE.fromExternal(encTrainingValue, tvProof);
        euint16 accuracy = FHE.fromExternal(encAccuracy, accProof);
        euint64 ftRoyalty = FHE.fromExternal(encFTRoyalty, ftrProof);
        id = licenseCount++;
        AIModelLicense storage _s0 = licenses[id];
        _s0.modelDeveloper = msg.sender;
        _s0.licensee = licensee;
        _s0.modelType = modelType;
        _s0.licenseType = licenseType;
        _s0.modelRef = modelRef;
        _s0.annualLicenseFeeUSD = annualFee;
        _s0.perCallPriceUSD = perCall;
        _s0.totalCallsUsed = FHE.asEuint64(0);
        _s0.trainingDataValueUSD = trainingValue;
        _s0.accuracyBenchmarkBps = accuracy;
        _s0.fineTuningRoyaltyBps = ftRoyalty;
        _s0.totalRevenueAccruedUSD = FHE.asEuint64(0);
        _s0.active = true;
        _s0.licenseStart = block.timestamp;
        _s0.licenseEnd = block.timestamp + durationDays * 1 days;
        _totalAILicenseRevenueUSD = FHE.add(_totalAILicenseRevenueUSD, annualFee);
        FHE.allowThis(licenses[id].annualLicenseFeeUSD); FHE.allow(licenses[id].annualLicenseFeeUSD, msg.sender); FHE.allow(licenses[id].annualLicenseFeeUSD, licensee);
        FHE.allowThis(licenses[id].perCallPriceUSD); FHE.allow(licenses[id].perCallPriceUSD, licensee);
        FHE.allowThis(licenses[id].totalCallsUsed); FHE.allow(licenses[id].totalCallsUsed, msg.sender);
        FHE.allowThis(licenses[id].trainingDataValueUSD); FHE.allow(licenses[id].trainingDataValueUSD, msg.sender);
        FHE.allowThis(licenses[id].accuracyBenchmarkBps);
        FHE.allowThis(licenses[id].fineTuningRoyaltyBps); FHE.allow(licenses[id].fineTuningRoyaltyBps, licensee);
        FHE.allowThis(licenses[id].totalRevenueAccruedUSD); FHE.allow(licenses[id].totalRevenueAccruedUSD, msg.sender);
        FHE.allowThis(_totalAILicenseRevenueUSD);
        emit LicenseCreated(id, modelType, licenseType);
    }

    function recordUsage(
        uint256 licenseId,
        externalEuint64 encCallCount, bytes calldata proof
    ) external nonReentrant {
        AIModelLicense storage l = licenses[licenseId];
        require(l.active && (msg.sender == l.licensee || isAIAuditor[msg.sender]), "Not authorized");
        euint64 callCount = FHE.fromExternal(encCallCount, proof);
        l.totalCallsUsed = FHE.add(l.totalCallsUsed, callCount);
        euint64 usageRevenue = FHE.mul(callCount, l.perCallPriceUSD);
        l.totalRevenueAccruedUSD = FHE.add(l.totalRevenueAccruedUSD, usageRevenue);
        _totalAILicenseRevenueUSD = FHE.add(_totalAILicenseRevenueUSD, usageRevenue);
        FHE.allowThis(l.totalCallsUsed); FHE.allow(l.totalCallsUsed, l.modelDeveloper);
        FHE.allowThis(l.totalRevenueAccruedUSD); FHE.allow(l.totalRevenueAccruedUSD, l.modelDeveloper);
        FHE.allowThis(_totalAILicenseRevenueUSD);
        emit UsageRecorded(licenseId, block.timestamp);
    }

    function revokeLicense(uint256 licenseId) external {
        require(msg.sender == licenses[licenseId].modelDeveloper || msg.sender == owner(), "Not authorized");
        licenses[licenseId].active = false;
        emit LicenseRevoked(licenseId);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalAILicenseRevenueUSD, viewer);
    }
}
