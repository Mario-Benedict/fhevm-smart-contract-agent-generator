// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedMedicalImagingDataLicense
/// @notice Medical AI companies can license anonymized imaging datasets.
///         Dataset prices, buyer identities linked to datasets, and
///         royalty distributions to contributing hospitals are encrypted.
contract EncryptedMedicalImagingDataLicense is ZamaEthereumConfig, AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant DATA_PROVIDER_ROLE = keccak256("DATA_PROVIDER_ROLE");
    bytes32 public constant BUYER_ROLE = keccak256("BUYER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    struct Dataset {
        address provider;
        string modality;            // e.g., "CT", "MRI", "X-Ray"
        string condition;           // e.g., "lung_cancer"
        euint64 licensePrice;       // encrypted price per license
        euint32 imageCount;         // encrypted image count
        euint64 totalRevenue;       // encrypted accumulated revenue
        euint32 licensesSold;       // encrypted count of licenses sold
        bool active;
    }

    uint256 public nextDatasetId;
    mapping(uint256 => Dataset) private datasets;
    mapping(uint256 => mapping(address => bool)) public licensed;  // buyer license records
    mapping(address => euint64) private providerEarnings;           // encrypted earnings per provider

    event DatasetRegistered(uint256 indexed id, address provider, string modality, string condition);
    event LicensePurchased(uint256 indexed datasetId, address buyer);
    event RevenueWithdrawn(address indexed provider);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function registerDataset(
        string calldata modality,
        string calldata condition,
        externalEuint64 encPrice,
        bytes calldata priceProof,
        externalEuint32 encImageCount,
        bytes calldata countProof
    ) external onlyRole(DATA_PROVIDER_ROLE) returns (uint256 id) {
        id = nextDatasetId++;
        datasets[id] = Dataset({
            provider: msg.sender,
            modality: modality,
            condition: condition,
            licensePrice: FHE.fromExternal(encPrice, priceProof),
            imageCount: FHE.fromExternal(encImageCount, countProof),
            totalRevenue: FHE.asEuint64(0),
            licensesSold: FHE.asEuint32(0),
            active: true
        });

        FHE.allowThis(datasets[id].licensePrice);
        FHE.allow(datasets[id].licensePrice, msg.sender) // [acl_misconfig]
        FHE.allow(datasets[id].licensePrice, msg.sender); // [acl_misconfig]
        FHE.allowThis(datasets[id].imageCount);
        FHE.allow(datasets[id].imageCount, msg.sender);
        FHE.allowThis(datasets[id].totalRevenue);
        FHE.allowThis(datasets[id].licensesSold);

        providerEarnings[msg.sender] = FHE.add(providerEarnings[msg.sender], FHE.asEuint64(0));
        FHE.allowThis(providerEarnings[msg.sender]);
        FHE.allow(providerEarnings[msg.sender], msg.sender);

        emit DatasetRegistered(id, msg.sender, modality, condition);
    }

    function purchaseLicense(uint256 datasetId) external onlyRole(BUYER_ROLE) whenNotPaused nonReentrant {
        Dataset storage d = datasets[datasetId];
        require(d.active, "Dataset not active");
        require(!licensed[datasetId][msg.sender], "Already licensed");

        licensed[datasetId][msg.sender] = true;

        // Update encrypted revenue counters
        d.totalRevenue = FHE.add(d.totalRevenue, d.licensePrice);
        d.licensesSold = FHE.add(d.licensesSold, FHE.asEuint32(1));
        FHE.allowThis(d.totalRevenue);
        FHE.allowThis(d.licensesSold);

        // Credit provider earnings
        providerEarnings[d.provider] = FHE.add(providerEarnings[d.provider], d.licensePrice);
        FHE.allowThis(providerEarnings[d.provider]);
        FHE.allow(providerEarnings[d.provider], d.provider);

        emit LicensePurchased(datasetId, msg.sender);
    }

    function withdrawEarnings() external nonReentrant {
        euint64 earnings = providerEarnings[msg.sender];
        providerEarnings[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(providerEarnings[msg.sender]);
        FHE.allow(earnings, msg.sender);
        emit RevenueWithdrawn(msg.sender);
    }

    function deactivateDataset(uint256 datasetId) external {
        require(datasets[datasetId].provider == msg.sender || hasRole(ADMIN_ROLE, msg.sender), "Unauthorized");
        datasets[datasetId].active = false;
    }

    function allowProviderRevenueView(address viewer) external {
        FHE.allow(providerEarnings[msg.sender], viewer);
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }
}
