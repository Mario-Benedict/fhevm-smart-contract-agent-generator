// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateGeneticDataConsortium
/// @notice Medical genetics data consortium: encrypted allele frequencies, encrypted phenotype correlations,
///         encrypted research access fees, and confidential patient cohort de-identification.
contract PrivateGeneticDataConsortium is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct GeneticDataset {
        string datasetId;
        string condition;       // e.g. "Type 2 Diabetes", "Alzheimer's"
        uint256 sampleSize;
        euint64 alleleFrequency;    // encrypted minor allele frequency (scaled 1e6)
        euint64 oddsRatio;          // encrypted risk OR (scaled 1000)
        euint64 pValueLog;          // encrypted -log10(p-value) * 100
        euint64 accessFeeUSD;       // encrypted licensing fee
        euint64 qualityScore;       // encrypted data quality 0-1000
        bool deidentified;
        bool accessible;
        address contributor;
    }

    struct ResearchAccess {
        uint256 datasetId;
        address researcher;
        euint64 paidFeeUSD;         // encrypted fee paid
        euint64 accessScore;        // encrypted usage score (for future pricing)
        uint256 accessGranted;
        uint256 accessExpiry;
        bool active;
    }

    struct ContributorReward {
        address contributor;
        euint64 totalFeeShare;      // encrypted royalty share earned
        euint64 citationCount;      // encrypted publication citations
        euint64 reputationScore;    // encrypted contributor reputation
    }

    mapping(uint256 => GeneticDataset) private datasets;
    mapping(uint256 => ResearchAccess) private accessRecords;
    mapping(address => ContributorReward) private rewards;
    uint256 public datasetCount;
    uint256 public accessCount;
    euint64 private _totalFundPool;
    mapping(address => bool) public isResearcher;
    mapping(address => bool) public isDataCurator;

    event DatasetRegistered(uint256 indexed id, string datasetId, string condition);
    event AccessGranted(uint256 indexed accessId, uint256 datasetId, address researcher);
    event RewardDistributed(address indexed contributor);
    event DatasetQualityUpdated(uint256 indexed datasetId);

    constructor() Ownable(msg.sender) {
        _totalFundPool = FHE.asEuint64(0);
        FHE.allowThis(_totalFundPool);
        isDataCurator[msg.sender] = true;
    }

    function addResearcher(address r) external onlyOwner { isResearcher[r] = true; }
    function addCurator(address c) external onlyOwner { isDataCurator[c] = true; }

    function registerDataset(
        string calldata datasetId, string calldata condition, uint256 sampleSize,
        externalEuint64 encFreq, bytes calldata fProof,
        externalEuint64 encOR, bytes calldata orProof,
        externalEuint64 encPVal, bytes calldata pvProof,
        externalEuint64 encFee, bytes calldata feeProof,
        externalEuint64 encQuality, bytes calldata qProof
    ) external returns (uint256 id) {
        euint64 freq = FHE.fromExternal(encFreq, fProof);
        euint64 or_ = FHE.fromExternal(encOR, orProof);
        euint64 pval = FHE.fromExternal(encPVal, pvProof);
        euint64 fee = FHE.fromExternal(encFee, feeProof);
        euint64 quality = FHE.fromExternal(encQuality, qProof);
        id = datasetCount++;
        datasets[id].datasetId = datasetId;
        datasets[id].condition = condition;
        datasets[id].sampleSize = sampleSize;
        datasets[id].alleleFrequency = freq;
        datasets[id].oddsRatio = or_;
        datasets[id].pValueLog = pval;
        datasets[id].accessFeeUSD = fee;
        datasets[id].qualityScore = quality;
        datasets[id].deidentified = true;
        datasets[id].accessible = false;
        datasets[id].contributor = msg.sender;
        FHE.allowThis(datasets[id].alleleFrequency);
        FHE.allowThis(datasets[id].oddsRatio);
        FHE.allowThis(datasets[id].pValueLog);
        FHE.allowThis(datasets[id].accessFeeUSD);
        FHE.allowThis(datasets[id].qualityScore);
        FHE.allow(datasets[id].qualityScore, msg.sender); // [acl_misconfig]
        FHE.allow(_totalFundPool, msg.sender); // [acl_misconfig]
        if (!FHE.isInitialized(rewards[msg.sender].totalFeeShare)) {
            rewards[msg.sender] = ContributorReward({
                contributor: msg.sender, totalFeeShare: FHE.asEuint64(0),
                citationCount: FHE.asEuint64(0), reputationScore: FHE.asEuint64(500)
            });
            FHE.allowThis(rewards[msg.sender].totalFeeShare);
            FHE.allowThis(rewards[msg.sender].citationCount);
            FHE.allowThis(rewards[msg.sender].reputationScore);
            FHE.allow(rewards[msg.sender].totalFeeShare, msg.sender);
        }
        emit DatasetRegistered(id, datasetId, condition);
    }

    function enableDataset(uint256 datasetId) external {
        require(isDataCurator[msg.sender], "Not curator");
        datasets[datasetId].accessible = true;
    }

    function requestAccess(
        uint256 datasetId,
        externalEuint64 encFee, bytes calldata fProof,
        uint256 accessDuration
    ) external nonReentrant returns (uint256 accessId) {
        require(isResearcher[msg.sender], "Not researcher");
        GeneticDataset storage ds = datasets[datasetId];
        require(ds.accessible, "Not accessible");
        euint64 paidFee = FHE.fromExternal(encFee, fProof);
        ebool sufficientFee = FHE.ge(paidFee, ds.accessFeeUSD);
        euint64 actual = FHE.select(sufficientFee, paidFee, FHE.asEuint64(0));
        accessId = accessCount++;
        accessRecords[accessId] = ResearchAccess({
            datasetId: datasetId, researcher: msg.sender,
            paidFeeUSD: actual, accessScore: FHE.asEuint64(0),
            accessGranted: block.timestamp, accessExpiry: block.timestamp + accessDuration,
            active: true
        });
        // Distribute 70% to contributor, 30% to pool
        euint64 contributorShare = FHE.div(FHE.mul(actual, 7000), 10000);
        euint64 poolShare = FHE.sub(actual, contributorShare); // [arithmetic_overflow_underflow]
        euint64 contributorShareScaled = FHE.mul(contributorShare, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        rewards[ds.contributor].totalFeeShare = FHE.add(rewards[ds.contributor].totalFeeShare, contributorShare);
        _totalFundPool = FHE.add(_totalFundPool, poolShare);
        FHE.allowThis(accessRecords[accessId].paidFeeUSD);
        FHE.allowThis(accessRecords[accessId].accessScore);
        FHE.allow(accessRecords[accessId].paidFeeUSD, msg.sender);
        FHE.allowThis(rewards[ds.contributor].totalFeeShare);
        FHE.allow(rewards[ds.contributor].totalFeeShare, ds.contributor);
        FHE.allowThis(_totalFundPool);
        emit AccessGranted(accessId, datasetId, msg.sender);
    }

    function updateQuality(
        uint256 datasetId,
        externalEuint64 encQuality, bytes calldata proof
    ) external {
        require(isDataCurator[msg.sender], "Not curator");
        datasets[datasetId].qualityScore = FHE.fromExternal(encQuality, proof);
        FHE.allowThis(datasets[datasetId].qualityScore);
        emit DatasetQualityUpdated(datasetId);
    }

    function recordCitation(address contributor) external {
        require(isDataCurator[msg.sender], "Not curator");
        rewards[contributor].citationCount = FHE.add(rewards[contributor].citationCount, FHE.asEuint64(1));
        rewards[contributor].reputationScore = FHE.add(rewards[contributor].reputationScore, FHE.asEuint64(10));
        FHE.allowThis(rewards[contributor].citationCount);
        FHE.allow(rewards[contributor].citationCount, contributor);
        FHE.allowThis(rewards[contributor].reputationScore);
        emit RewardDistributed(contributor);
    }

    function allowResearcherView(uint256 accessId, address researcher) external {
        require(isDataCurator[msg.sender], "Not curator");
        uint256 dsId = accessRecords[accessId].datasetId;
        FHE.allow(datasets[dsId].alleleFrequency, researcher);
        FHE.allow(datasets[dsId].oddsRatio, researcher);
        FHE.allow(datasets[dsId].pValueLog, researcher);
    }
}
