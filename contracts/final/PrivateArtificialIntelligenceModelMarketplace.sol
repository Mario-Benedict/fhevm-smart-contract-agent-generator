// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateArtificialIntelligenceModelMarketplace
/// @notice AI model licensing marketplace where model performance benchmarks,
///         training costs, inference pricing, and royalty splits are encrypted.
contract PrivateArtificialIntelligenceModelMarketplace is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ModelType { LLM, VISION, AUDIO, MULTIMODAL, REINFORCEMENT, DIFFUSION }
    enum LicenseScope { INFERENCE_ONLY, FINE_TUNING, FULL_WEIGHTS, API_ACCESS }

    struct AIModel {
        string modelName;
        string modelVersion;
        ModelType modelType;
        address creator;
        euint64 trainingCostUSD;       // encrypted training investment
        euint64 benchmarkScore;        // encrypted MMLU/HumanEval score (scaled)
        euint64 inferenceLatencyMs;    // encrypted p50 latency
        euint64 listingPriceUSD;       // encrypted base license price
        euint64 perQueryPriceUSD;      // encrypted per-inference pricing
        euint64 royaltyBps;            // encrypted creator royalty
        euint32 parametersBillions;    // encrypted model size
        euint32 totalLicenses;         // encrypted licenses issued
        euint64 totalRevenueUSD;       // encrypted total earned
        bool listed;
    }

    struct ModelLicense {
        uint256 modelId;
        address licensee;
        LicenseScope scope;
        euint64 pricePaidUSD;          // encrypted
        euint64 queryLimit;            // encrypted allowed queries
        euint64 queriesUsed;           // encrypted queries consumed
        euint64 expiryTimestamp;       // encrypted license expiry
        bool active;
    }

    mapping(uint256 => AIModel) private models;
    mapping(uint256 => ModelLicense) private licenses;
    mapping(address => bool) public isVerifiedCreator;
    uint256 public modelCount;
    uint256 public licenseCount;
    euint64 private _platformTotalRevenue;
    euint64 private _totalCreatorRoyalties;

    event ModelListed(uint256 indexed modelId, ModelType mType);
    event LicenseIssued(uint256 indexed licenseId, uint256 modelId, address licensee);
    event QueryConsumed(uint256 indexed licenseId);
    event RoyaltyPaid(uint256 indexed modelId, address creator);

    constructor() Ownable(msg.sender) {
        _platformTotalRevenue = FHE.asEuint64(0);
        _totalCreatorRoyalties = FHE.asEuint64(0);
        FHE.allowThis(_platformTotalRevenue);
        FHE.allowThis(_totalCreatorRoyalties);
        isVerifiedCreator[msg.sender] = true;
    }

    function addCreator(address c) external onlyOwner { isVerifiedCreator[c] = true; }

    function listModel(
        string calldata name, string calldata version, ModelType mType,
        externalEuint64 encTrainingCost, bytes calldata tcProof,
        externalEuint64 encBenchmark,    bytes calldata bmProof,
        externalEuint64 encListingPrice, bytes calldata lpProof,
        externalEuint64 encPerQuery,     bytes calldata pqProof,
        externalEuint64 encRoyalty,      bytes calldata rProof,
        externalEuint32 encParams,       bytes calldata parProof
    ) external returns (uint256 modelId) {
        require(isVerifiedCreator[msg.sender], "Not verified creator");
        euint64 trainCost = FHE.fromExternal(encTrainingCost, tcProof);
        euint64 benchmark = FHE.fromExternal(encBenchmark, bmProof);
        euint64 listPrice = FHE.fromExternal(encListingPrice, lpProof);
        euint64 perQuery  = FHE.fromExternal(encPerQuery, pqProof);
        euint64 royalty   = FHE.fromExternal(encRoyalty, rProof);
        euint32 params    = FHE.fromExternal(encParams, parProof);
        modelId = modelCount++;
        AIModel storage _s0 = models[modelId];
        _s0.modelName = name;
        _s0.modelVersion = version;
        _s0.modelType = mType;
        _s0.creator = msg.sender;
        _s0.trainingCostUSD = trainCost;
        _s0.benchmarkScore = benchmark;
        _s0.inferenceLatencyMs = FHE.asEuint64(0);
        _s0.listingPriceUSD = listPrice;
        _s0.perQueryPriceUSD = perQuery;
        _s0.royaltyBps = royalty;
        _s0.parametersBillions = params;
        _s0.totalLicenses = FHE.asEuint32(0);
        _s0.totalRevenueUSD = FHE.asEuint64(0);
        _s0.listed = true;
        FHE.allowThis(models[modelId].trainingCostUSD);
        FHE.allow(models[modelId].trainingCostUSD, msg.sender);
        FHE.allowThis(models[modelId].benchmarkScore);
        FHE.allowThis(models[modelId].listingPriceUSD);
        FHE.allowThis(models[modelId].perQueryPriceUSD);
        FHE.allowThis(models[modelId].royaltyBps);
        FHE.allow(models[modelId].royaltyBps, msg.sender);
        FHE.allowThis(models[modelId].parametersBillions);
        FHE.allowThis(models[modelId].totalLicenses);
        FHE.allowThis(models[modelId].totalRevenueUSD);
        FHE.allow(models[modelId].totalRevenueUSD, msg.sender);
        emit ModelListed(modelId, mType);
    }

    function purchaseLicense(
        uint256 modelId,
        LicenseScope scope,
        externalEuint64 encQueryLimit, bytes calldata qlProof,
        externalEuint64 encExpiry,     bytes calldata expProof
    ) external nonReentrant returns (uint256 licenseId) {
        require(models[modelId].listed, "Model not listed");
        euint64 queryLimit = FHE.fromExternal(encQueryLimit, qlProof);
        euint64 expiry     = FHE.fromExternal(encExpiry, expProof);
        euint64 royalty    = FHE.div(FHE.mul(models[modelId].listingPriceUSD, models[modelId].royaltyBps), 10000);
        licenseId = licenseCount++;
        licenses[licenseId] = ModelLicense({
            modelId: modelId, licensee: msg.sender, scope: scope,
            pricePaidUSD: models[modelId].listingPriceUSD,
            queryLimit: queryLimit, queriesUsed: FHE.asEuint64(0),
            expiryTimestamp: expiry, active: true
        });
        models[modelId].totalLicenses = FHE.add(models[modelId].totalLicenses, FHE.asEuint32(1));
        models[modelId].totalRevenueUSD = FHE.add(models[modelId].totalRevenueUSD, models[modelId].listingPriceUSD);
        _platformTotalRevenue = FHE.add(_platformTotalRevenue, FHE.sub(models[modelId].listingPriceUSD, royalty));
        _totalCreatorRoyalties = FHE.add(_totalCreatorRoyalties, royalty);
        FHE.allowThis(licenses[licenseId].pricePaidUSD);
        FHE.allow(licenses[licenseId].pricePaidUSD, msg.sender);
        FHE.allowThis(licenses[licenseId].queryLimit);
        FHE.allow(licenses[licenseId].queryLimit, msg.sender);
        FHE.allowThis(licenses[licenseId].queriesUsed);
        FHE.allow(licenses[licenseId].queriesUsed, msg.sender);
        FHE.allowThis(licenses[licenseId].expiryTimestamp);
        FHE.allow(licenses[licenseId].expiryTimestamp, msg.sender);
        FHE.allowThis(models[modelId].totalLicenses);
        FHE.allowThis(models[modelId].totalRevenueUSD);
        FHE.allowThis(_platformTotalRevenue);
        FHE.allowThis(_totalCreatorRoyalties);
        emit LicenseIssued(licenseId, modelId, msg.sender);
        emit RoyaltyPaid(modelId, models[modelId].creator);
    }

    function consumeQuery(uint256 licenseId) external {
        require(licenses[licenseId].licensee == msg.sender, "Not licensee");
        require(licenses[licenseId].active, "License inactive");
        licenses[licenseId].queriesUsed = FHE.add(licenses[licenseId].queriesUsed, FHE.asEuint64(1));
        ebool limitReached = FHE.ge(licenses[licenseId].queriesUsed, licenses[licenseId].queryLimit);
        if (FHE.isInitialized(limitReached)) {
            licenses[licenseId].active = false;
        }
        FHE.allowThis(licenses[licenseId].queriesUsed);
        FHE.allow(licenses[licenseId].queriesUsed, msg.sender);
        emit QueryConsumed(licenseId);
    }

    function allowMarketplaceView(address viewer) external onlyOwner {
        FHE.allow(_platformTotalRevenue, viewer);
        FHE.allow(_totalCreatorRoyalties, viewer);
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