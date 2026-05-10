// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedBiomedicalDataMarket
/// @notice Biomedical dataset marketplace: researchers buy access to encrypted patient
///         datasets with encrypted pricing; patient consent tracked privately.
contract EncryptedBiomedicalDataMarket is ZamaEthereumConfig, Ownable {
    struct Dataset {
        string description;
        string dataCategory;          // genomics, imaging, EMR, wearables
        address dataOwner;
        euint32 recordCount;          // encrypted number of patient records
        euint64 accessPriceUSD;       // encrypted access fee
        euint8 privacyGuarantee;      // encrypted 0-100 differential privacy score
        euint64 totalRevenue;         // encrypted revenue generated
        uint256 createdAt;
        bool active;
    }

    struct ResearchAccess {
        uint256 datasetId;
        address researcher;
        euint64 feePaid;              // encrypted fee paid
        uint256 accessGranted;
        uint256 accessExpiry;
        bool active;
    }

    struct PatientConsent {
        address patient;
        euint8 consentLevel;          // encrypted 0=no consent, 1=research, 2=commercial
        bool consented;
    }

    mapping(uint256 => Dataset) private datasets;
    mapping(uint256 => ResearchAccess) private accessRecords;
    mapping(address => mapping(uint256 => PatientConsent)) private consents;
    mapping(address => euint64) private _dataOwnerBalance;
    mapping(address => bool) public isResearcher;
    mapping(address => bool) public isDataCurator;
    uint256 public datasetCount;
    uint256 public accessCount;
    euint64 private _platformRevenue;
    euint64 private _platformFeeBps;

    event DatasetListed(uint256 indexed id, string category, address owner);
    event AccessPurchased(uint256 indexed accessId, uint256 datasetId, address researcher);
    event ConsentUpdated(address indexed patient, uint256 datasetId);

    constructor(externalEuint64 encFee, bytes memory proof) Ownable(msg.sender) {
        _platformFeeBps = FHE.fromExternal(encFee, proof);
        _platformRevenue = FHE.asEuint64(0);
        FHE.allowThis(_platformFeeBps);
        FHE.allowThis(_platformRevenue);
        isDataCurator[msg.sender] = true;
    }

    function addResearcher(address r) external onlyOwner { isResearcher[r] = true; }
    function addCurator(address c) external onlyOwner { isDataCurator[c] = true; }

    function listDataset(
        string calldata description, string calldata category,
        externalEuint32 encRecords, bytes calldata rProof,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint8 encPrivacy, bytes calldata ppProof
    ) external returns (uint256 id) {
        require(isDataCurator[msg.sender], "Not curator");
        euint32 records = FHE.fromExternal(encRecords, rProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint8 privacy = FHE.fromExternal(encPrivacy, ppProof);
        id = datasetCount++;
        datasets[id].description = description;
        datasets[id].dataCategory = category;
        datasets[id].dataOwner = msg.sender;
        datasets[id].recordCount = records;
        datasets[id].accessPriceUSD = price;
        datasets[id].privacyGuarantee = privacy;
        datasets[id].totalRevenue = FHE.asEuint64(0);
        datasets[id].createdAt = block.timestamp;
        datasets[id].active = true;
        FHE.allowThis(datasets[id].recordCount);
        FHE.allow(datasets[id].recordCount, msg.sender);
        FHE.allowThis(datasets[id].accessPriceUSD);
        FHE.allowThis(datasets[id].privacyGuarantee);
        FHE.allow(datasets[id].privacyGuarantee, msg.sender);
        FHE.allowThis(datasets[id].totalRevenue);
        if (!FHE.isInitialized(_dataOwnerBalance[msg.sender])) {
            _dataOwnerBalance[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_dataOwnerBalance[msg.sender]);
        }
        emit DatasetListed(id, category, msg.sender);
    }

    function purchaseAccess(uint256 datasetId, externalEuint64 encPayment, bytes calldata proof, uint256 accessDays)
        external returns (uint256 accessId)
    {
        require(isResearcher[msg.sender], "Not researcher");
        Dataset storage ds = datasets[datasetId];
        require(ds.active, "Dataset inactive");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        ebool feeSufficient = FHE.ge(payment, ds.accessPriceUSD);
        euint64 accepted = FHE.select(feeSufficient, ds.accessPriceUSD, FHE.asEuint64(0));
        euint64 platformFee = FHE.div(FHE.mul(accepted, _platformFeeBps), 10000);
        ebool _safeSub164 = FHE.ge(accepted, platformFee);
        euint64 ownerNet = FHE.select(_safeSub164, FHE.sub(accepted, platformFee), FHE.asEuint64(0));
        ds.totalRevenue = FHE.add(ds.totalRevenue, ownerNet);
        _platformRevenue = FHE.add(_platformRevenue, platformFee);
        _dataOwnerBalance[ds.dataOwner] = FHE.add(_dataOwnerBalance[ds.dataOwner], ownerNet);
        accessId = accessCount++;
        accessRecords[accessId] = ResearchAccess({
            datasetId: datasetId, researcher: msg.sender, feePaid: accepted,
            accessGranted: block.timestamp, accessExpiry: block.timestamp + accessDays * 1 days, active: true
        });
        FHE.allowThis(ds.totalRevenue);
        FHE.allowThis(_platformRevenue);
        FHE.allowThis(_dataOwnerBalance[ds.dataOwner]);
        FHE.allow(_dataOwnerBalance[ds.dataOwner], ds.dataOwner);
        FHE.allowThis(accessRecords[accessId].feePaid);
        FHE.allow(accessRecords[accessId].feePaid, msg.sender);
        // Grant access to dataset metadata
        FHE.allow(ds.recordCount, msg.sender);
        FHE.allow(ds.privacyGuarantee, msg.sender);
        emit AccessPurchased(accessId, datasetId, msg.sender);
    }

    function updateConsent(uint256 datasetId, externalEuint8 encConsentLevel, bytes calldata proof) external {
        euint8 level = FHE.fromExternal(encConsentLevel, proof);
        consents[msg.sender][datasetId] = PatientConsent({ patient: msg.sender, consentLevel: level, consented: true });
        FHE.allowThis(consents[msg.sender][datasetId].consentLevel);
        FHE.allow(consents[msg.sender][datasetId].consentLevel, msg.sender);
        emit ConsentUpdated(msg.sender, datasetId);
    }

    function ownerWithdraw() external {
        euint64 bal = _dataOwnerBalance[msg.sender];
        _dataOwnerBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_dataOwnerBalance[msg.sender]);
        FHE.allow(bal, msg.sender);
    }

    function allowDatasetStats(uint256 id, address viewer) external {
        require(datasets[id].dataOwner == msg.sender || isDataCurator[msg.sender], "Unauthorized");
        FHE.allow(datasets[id].recordCount, viewer);
        FHE.allow(datasets[id].accessPriceUSD, viewer);
        FHE.allow(datasets[id].totalRevenue, viewer);
    }
}
