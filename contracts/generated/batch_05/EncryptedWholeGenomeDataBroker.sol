// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedWholeGenomeDataBroker
/// @notice A marketplace where genomic datasets are tokenized and licensed
///         with encrypted royalty splits. Researchers access encrypted summaries;
///         individual sequences remain in FHE vaults controlled by donors.
contract EncryptedWholeGenomeDataBroker is ZamaEthereumConfig, Ownable {
    struct GenomeDataset {
        euint64 licenseFeeUSD;      // fee to access the dataset
        euint32 royaltyToOwnerBps;  // portion going to genome donor
        euint32 dataQualityScore;   // 0-10000
        euint32 sampleCount;        // number of subjects (encrypted)
        address owner;
        bool active;
        uint256 registeredAt;
        uint256 accessCount;
    }

    struct AccessLicense {
        euint64 amountPaid;
        uint256 grantedAt;
        uint256 expiresAt;
        bool active;
    }

    mapping(bytes32 => GenomeDataset) private datasets;
    mapping(address => mapping(bytes32 => AccessLicense)) private licenses;
    mapping(address => euint64) private ownerRoyalties;
    mapping(address => bool) private ownerRoyaltiesInitialized;
    mapping(address => bytes32[]) public ownerDatasets;
    bytes32[] public datasetList;

    euint64 private _totalPlatformRevenue;
    euint32 private _platformFeeBps;

    event DatasetRegistered(bytes32 indexed datasetId, address indexed owner);
    event LicenseGranted(bytes32 indexed datasetId, address indexed researcher);
    event RoyaltyWithdrawn(address indexed owner);

    constructor(externalEuint32 encPlatformFee, bytes memory feeProof) Ownable(msg.sender) {
        _platformFeeBps = FHE.fromExternal(encPlatformFee, feeProof);
        _totalPlatformRevenue = FHE.asEuint64(0);
        FHE.allowThis(_platformFeeBps);
        FHE.allowThis(_totalPlatformRevenue);
    }

    function registerDataset(
        externalEuint64 encFee, bytes calldata feeProof,
        externalEuint32 encRoyalty, bytes calldata royaltyProof,
        externalEuint32 encQuality, bytes calldata qualProof,
        externalEuint32 encSamples, bytes calldata sampProof
    ) external returns (bytes32 datasetId) {
        datasetId = keccak256(abi.encodePacked(msg.sender, block.timestamp, datasetList.length));
        GenomeDataset storage d = datasets[datasetId];
        d.licenseFeeUSD = FHE.fromExternal(encFee, feeProof);
        d.royaltyToOwnerBps = FHE.fromExternal(encRoyalty, royaltyProof);
        d.dataQualityScore = FHE.fromExternal(encQuality, qualProof);
        d.sampleCount = FHE.fromExternal(encSamples, sampProof);
        d.owner = msg.sender;
        d.active = true;
        d.registeredAt = block.timestamp;
        if (!ownerRoyaltiesInitialized[msg.sender]) {
            ownerRoyalties[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(ownerRoyalties[msg.sender]);
            ownerRoyaltiesInitialized[msg.sender] = true;
        }
        FHE.allowThis(d.licenseFeeUSD);
        FHE.allow(d.licenseFeeUSD, msg.sender);
        FHE.allowThis(d.royaltyToOwnerBps);
        FHE.allowThis(d.dataQualityScore);
        FHE.allow(d.dataQualityScore, msg.sender);
        FHE.allowThis(d.sampleCount);
        datasetList.push(datasetId);
        ownerDatasets[msg.sender].push(datasetId);
        emit DatasetRegistered(datasetId, msg.sender);
    }

    function purchaseLicense(
        bytes32 datasetId,
        externalEuint64 encPayment, bytes calldata proof,
        uint256 licenseDays
    ) external {
        GenomeDataset storage d = datasets[datasetId];
        require(d.active, "Dataset inactive");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        ebool sufficientPayment = FHE.ge(payment, d.licenseFeeUSD);
        euint64 royalty = FHE.select(sufficientPayment, FHE.div(payment, 5), FHE.asEuint64(0)); // 20% to owner
        euint64 platform = FHE.select(sufficientPayment, FHE.sub(payment, royalty), FHE.asEuint64(0));
        if (!ownerRoyaltiesInitialized[d.owner]) {
            ownerRoyalties[d.owner] = FHE.asEuint64(0);
            FHE.allowThis(ownerRoyalties[d.owner]);
            ownerRoyaltiesInitialized[d.owner] = true;
        }
        ownerRoyalties[d.owner] = FHE.add(ownerRoyalties[d.owner], royalty);
        _totalPlatformRevenue = FHE.add(_totalPlatformRevenue, platform);
        d.accessCount++;
        licenses[msg.sender][datasetId].amountPaid = payment;
        licenses[msg.sender][datasetId].grantedAt = block.timestamp;
        licenses[msg.sender][datasetId].expiresAt = block.timestamp + (licenseDays * 1 days);
        licenses[msg.sender][datasetId].active = true;
        FHE.allowThis(ownerRoyalties[d.owner]);
        FHE.allow(ownerRoyalties[d.owner], d.owner);
        FHE.allowThis(_totalPlatformRevenue);
        FHE.allowThis(licenses[msg.sender][datasetId].amountPaid);
        FHE.allow(licenses[msg.sender][datasetId].amountPaid, msg.sender);
        FHE.allow(d.dataQualityScore, msg.sender);
        FHE.allow(d.sampleCount, msg.sender);
        emit LicenseGranted(datasetId, msg.sender);
    }

    function withdrawRoyalties() external {
        require(ownerRoyaltiesInitialized[msg.sender], "No royalties");
        euint64 amount = ownerRoyalties[msg.sender];
        ownerRoyalties[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(ownerRoyalties[msg.sender]);
        FHE.allow(amount, msg.sender);
        emit RoyaltyWithdrawn(msg.sender);
    }

    function allowPlatformMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalPlatformRevenue, viewer);
    }
}
