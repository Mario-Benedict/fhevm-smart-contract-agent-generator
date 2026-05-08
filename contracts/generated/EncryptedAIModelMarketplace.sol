// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedAIModelMarketplace
/// @notice AI model licensing marketplace: encrypted model performance benchmarks,
///         encrypted licensing fees, encrypted compute cost estimates, and private API usage metering.
contract EncryptedAIModelMarketplace is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ModelType { LLM, VISION, MULTIMODAL, AUDIO, TIMESERIES, REINFORCEMENT }
    enum LicenseType { PER_CALL, SUBSCRIPTION, PERPETUAL, RESEARCH }

    struct AIModel {
        string modelName;
        string modelVersion;
        ModelType modelType;
        address provider;
        euint64 accuracyBps;         // encrypted benchmark accuracy (basis points)
        euint64 latencyMs;           // encrypted inference latency
        euint64 pricePerCallUSD;     // encrypted per-call fee
        euint64 monthlySubscription; // encrypted monthly subscription
        euint64 totalRevenue;        // encrypted lifetime revenue
        euint64 totalCalls;          // encrypted total API calls
        bool active;
    }

    struct LicenseHolder {
        uint256 modelId;
        LicenseType licenseType;
        euint64 callsRemaining;      // encrypted remaining API calls
        euint64 prepaidBalance;      // encrypted prepaid balance
        euint64 totalCallsMade;      // encrypted total calls made
        euint64 spendUSD;            // encrypted total spend
        uint256 subscriptionExpiry;
        bool active;
    }

    struct UsageReport {
        uint256 licenseId;
        euint64 callsThisPeriod;    // encrypted usage
        euint64 computeCostUSD;     // encrypted compute cost
        uint256 period;
    }

    mapping(uint256 => AIModel) private models;
    mapping(bytes32 => LicenseHolder) private licenses; // keccak(user, modelId)
    mapping(uint256 => UsageReport[]) private usageReports;
    uint256 public modelCount;
    euint64 private _platformRevenueFee; // 5% platform fee
    euint64 private _totalPlatformRevenue;
    mapping(address => bool) public isModelProvider;
    mapping(address => bool) public isPlatformAdmin;

    event ModelRegistered(uint256 indexed id, string name, ModelType modelType);
    event LicenseIssued(bytes32 indexed licenseId, uint256 modelId, address user, LicenseType licType);
    event APICallMade(bytes32 indexed licenseId, uint256 modelId);
    event UsageReported(uint256 indexed reportId, uint256 modelId);
    event ModelDeactivated(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _platformRevenueFee = FHE.asEuint64(500); // 5% in bps
        _totalPlatformRevenue = FHE.asEuint64(0);
        FHE.allowThis(_platformRevenueFee);
        FHE.allowThis(_totalPlatformRevenue);
        isPlatformAdmin[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isPlatformAdmin[a] = true; }

    function registerModel(
        string calldata name, string calldata version, ModelType modelType,
        externalEuint64 encAccuracy, bytes calldata aProof,
        externalEuint64 encLatency, bytes calldata lProof,
        externalEuint64 encPricePerCall, bytes calldata pProof,
        externalEuint64 encMonthlyFee, bytes calldata mProof
    ) external returns (uint256 id) {
        euint64 accuracy = FHE.fromExternal(encAccuracy, aProof);
        euint64 latency = FHE.fromExternal(encLatency, lProof);
        euint64 priceCall = FHE.fromExternal(encPricePerCall, pProof);
        euint64 monthly = FHE.fromExternal(encMonthlyFee, mProof);
        id = modelCount++;
        models[id] = AIModel({
            modelName: name, modelVersion: version, modelType: modelType,
            provider: msg.sender, accuracyBps: accuracy, latencyMs: latency,
            pricePerCallUSD: priceCall, monthlySubscription: monthly,
            totalRevenue: FHE.asEuint64(0), totalCalls: FHE.asEuint64(0), active: true
        });
        FHE.allowThis(models[id].accuracyBps);
        FHE.allowThis(models[id].latencyMs);
        FHE.allowThis(models[id].pricePerCallUSD);
        FHE.allowThis(models[id].monthlySubscription);
        FHE.allowThis(models[id].totalRevenue);
        FHE.allowThis(models[id].totalCalls);
        emit ModelRegistered(id, name, modelType);
    }

    function issueLicense(
        uint256 modelId, LicenseType licType,
        externalEuint64 encBalance, bytes calldata bProof,
        externalEuint64 encCalls, bytes calldata cProof,
        uint256 subExpiry
    ) external nonReentrant returns (bytes32 licId) {
        require(models[modelId].active, "Model inactive");
        euint64 balance = FHE.fromExternal(encBalance, bProof);
        euint64 calls = FHE.fromExternal(encCalls, cProof);
        licId = keccak256(abi.encodePacked(msg.sender, modelId, block.timestamp));
        licenses[licId] = LicenseHolder({
            modelId: modelId, licenseType: licType,
            callsRemaining: calls, prepaidBalance: balance,
            totalCallsMade: FHE.asEuint64(0), spendUSD: FHE.asEuint64(0),
            subscriptionExpiry: subExpiry, active: true
        });
        FHE.allowThis(licenses[licId].callsRemaining);
        FHE.allowThis(licenses[licId].prepaidBalance);
        FHE.allowThis(licenses[licId].totalCallsMade);
        FHE.allowThis(licenses[licId].spendUSD);
        FHE.allow(licenses[licId].callsRemaining, msg.sender);
        FHE.allow(licenses[licId].prepaidBalance, msg.sender);
        emit LicenseIssued(licId, modelId, msg.sender, licType);
    }

    function makeAPICall(bytes32 licId) external nonReentrant {
        LicenseHolder storage lic = licenses[licId];
        require(lic.active, "License inactive");
        AIModel storage model = models[lic.modelId];
        require(model.active, "Model inactive");
        // Deduct call
        ebool hasCallCredit = FHE.ge(lic.callsRemaining, FHE.asEuint64(1));
        euint64 callDeduct = FHE.select(hasCallCredit, FHE.asEuint64(1), FHE.asEuint64(0));
        lic.callsRemaining = FHE.sub(lic.callsRemaining, callDeduct);
        // Deduct payment if per-call license
        ebool hasBalance = FHE.ge(lic.prepaidBalance, model.pricePerCallUSD);
        euint64 charge = FHE.select(hasBalance, model.pricePerCallUSD, lic.prepaidBalance);
        lic.prepaidBalance = FHE.sub(lic.prepaidBalance, charge);
        lic.totalCallsMade = FHE.add(lic.totalCallsMade, FHE.asEuint64(1));
        lic.spendUSD = FHE.add(lic.spendUSD, charge);
        // Platform fee
        euint64 platformFee = FHE.div(FHE.mul(charge, _platformRevenueFee), 10000);
        euint64 providerShare = FHE.sub(charge, platformFee);
        model.totalRevenue = FHE.add(model.totalRevenue, providerShare);
        model.totalCalls = FHE.add(model.totalCalls, FHE.asEuint64(1));
        _totalPlatformRevenue = FHE.add(_totalPlatformRevenue, platformFee);
        FHE.allowThis(lic.callsRemaining);
        FHE.allow(lic.callsRemaining, msg.sender);
        FHE.allowThis(lic.prepaidBalance);
        FHE.allow(lic.prepaidBalance, msg.sender);
        FHE.allowThis(lic.totalCallsMade);
        FHE.allowThis(model.totalRevenue);
        FHE.allow(model.totalRevenue, model.provider);
        FHE.allowThis(model.totalCalls);
        FHE.allowThis(_totalPlatformRevenue);
        emit APICallMade(licId, lic.modelId);
    }

    function topUpLicense(bytes32 licId, externalEuint64 encAmount, bytes calldata proof) external {
        require(licenses[licId].active, "Inactive");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        licenses[licId].prepaidBalance = FHE.add(licenses[licId].prepaidBalance, amount);
        FHE.allowThis(licenses[licId].prepaidBalance);
        FHE.allow(licenses[licId].prepaidBalance, msg.sender);
    }

    function deactivateModel(uint256 modelId) external {
        require(models[modelId].provider == msg.sender || isPlatformAdmin[msg.sender], "Not authorized");
        models[modelId].active = false;
        emit ModelDeactivated(modelId);
    }

    function allowProviderView(uint256 modelId, address provider) external {
        require(isPlatformAdmin[msg.sender], "Not admin");
        FHE.allow(models[modelId].totalRevenue, provider);
        FHE.allow(models[modelId].totalCalls, provider);
        FHE.allow(models[modelId].accuracyBps, provider);
    }
}
