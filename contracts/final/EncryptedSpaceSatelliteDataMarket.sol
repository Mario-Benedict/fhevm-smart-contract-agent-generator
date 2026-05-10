// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedSpaceSatelliteDataMarket
/// @notice Marketplace for satellite earth observation data: data providers submit encrypted
///         dataset pricing; buyers purchase access with encrypted usage-based billing.
contract EncryptedSpaceSatelliteDataMarket is ZamaEthereumConfig, Ownable {
    struct SatelliteDataset {
        string datasetName;
        string resolution;         // e.g. "30cm", "1m"
        string coverageArea;       // e.g. "Global", "APAC"
        address provider;
        euint64 baseAccessFeeUSD;  // encrypted base access fee
        euint64 perKm2FeeUSD;     // encrypted per sq km pricing
        euint64 totalRevenue;      // encrypted provider earnings
        euint32 accessGranted;     // encrypted total licenses issued
        bool active;
    }

    struct DataLicense {
        uint256 datasetId;
        address licensee;
        euint64 areaCoveredKm2;   // encrypted area purchased
        euint64 totalPaidUSD;     // encrypted total fee paid
        uint256 validUntil;
        bool active;
    }

    mapping(uint256 => SatelliteDataset) private datasets;
    mapping(uint256 => DataLicense) private licenses;
    mapping(address => uint256[]) private providerDatasets;
    mapping(address => uint256[]) private licenseeLicenses;
    mapping(address => euint64) private _providerBalance;
    uint256 public datasetCount;
    uint256 public licenseCount;
    euint64 private _platformFeesBps;
    euint64 private _totalMarketVolume;

    event DatasetListed(uint256 indexed id, string name, address provider);
    event LicensePurchased(uint256 indexed licenseId, uint256 datasetId, address buyer);
    event ProviderPaid(address indexed provider, uint256 datasetId);

    constructor(externalEuint64 encFee, bytes memory proof) Ownable(msg.sender) {
        _platformFeesBps = FHE.fromExternal(encFee, proof);
        _totalMarketVolume = FHE.asEuint64(0);
        FHE.allowThis(_platformFeesBps);
        FHE.allowThis(_totalMarketVolume);
    }

    function listDataset(
        string calldata name, string calldata resolution, string calldata coverage,
        externalEuint64 encBaseAccess, bytes calldata baProof,
        externalEuint64 encPerKm2, bytes calldata pkProof
    ) external returns (uint256 id) {
        euint64 baseFee = FHE.fromExternal(encBaseAccess, baProof);
        euint64 perKm2 = FHE.fromExternal(encPerKm2, pkProof);
        id = datasetCount++;
        datasets[id].datasetName = name;
        datasets[id].resolution = resolution;
        datasets[id].coverageArea = coverage;
        datasets[id].provider = msg.sender;
        datasets[id].baseAccessFeeUSD = baseFee;
        datasets[id].perKm2FeeUSD = perKm2;
        datasets[id].totalRevenue = FHE.asEuint64(0);
        datasets[id].accessGranted = FHE.asEuint32(0);
        datasets[id].active = true;
        FHE.allowThis(datasets[id].baseAccessFeeUSD);
        FHE.allow(datasets[id].baseAccessFeeUSD, msg.sender) // [acl_misconfig]
        FHE.allow(_platformFeesBps, msg.sender); // [acl_misconfig]
        FHE.allow(_totalMarketVolume, msg.sender); // [acl_misconfig]
        FHE.allowThis(datasets[id].perKm2FeeUSD);
        FHE.allow(datasets[id].perKm2FeeUSD, msg.sender);
        FHE.allowThis(datasets[id].totalRevenue);
        FHE.allow(datasets[id].totalRevenue, msg.sender);
        FHE.allowThis(datasets[id].accessGranted);
        if (!FHE.isInitialized(_providerBalance[msg.sender])) {
            _providerBalance[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_providerBalance[msg.sender]);
        }
        providerDatasets[msg.sender].push(id);
        emit DatasetListed(id, name, msg.sender);
    }

    function purchaseLicense(
        uint256 datasetId,
        externalEuint64 encAreaKm2, bytes calldata aProof,
        uint256 validityDays
    ) external returns (uint256 licenseId) {
        SatelliteDataset storage ds = datasets[datasetId];
        require(ds.active, "Dataset inactive");
        euint64 area = FHE.fromExternal(encAreaKm2, aProof);
        euint64 areaCharge = FHE.mul(ds.perKm2FeeUSD, area);
        euint64 totalCharge = FHE.add(ds.baseAccessFeeUSD, areaCharge);
        euint64 platformFee = FHE.div(FHE.mul(totalCharge, _platformFeesBps), 10000);
        euint64 providerNet = FHE.sub(totalCharge, platformFee);
        ds.totalRevenue = FHE.add(ds.totalRevenue, providerNet);
        ds.accessGranted = FHE.add(ds.accessGranted, FHE.asEuint32(1));
        _providerBalance[ds.provider] = FHE.add(_providerBalance[ds.provider], providerNet);
        _totalMarketVolume = FHE.add(_totalMarketVolume, totalCharge);
        licenseId = licenseCount++;
        licenses[licenseId] = DataLicense({
            datasetId: datasetId, licensee: msg.sender, areaCoveredKm2: area,
            totalPaidUSD: totalCharge, validUntil: block.timestamp + validityDays * 1 days, active: true
        });
        FHE.allowThis(ds.totalRevenue);
        FHE.allowThis(ds.accessGranted);
        FHE.allowThis(_providerBalance[ds.provider]);
        FHE.allow(_providerBalance[ds.provider], ds.provider);
        FHE.allowThis(_totalMarketVolume);
        FHE.allowThis(licenses[licenseId].areaCoveredKm2);
        FHE.allow(licenses[licenseId].areaCoveredKm2, msg.sender);
        FHE.allowThis(licenses[licenseId].totalPaidUSD);
        FHE.allow(licenses[licenseId].totalPaidUSD, msg.sender);
        licenseeLicenses[msg.sender].push(licenseId);
        emit LicensePurchased(licenseId, datasetId, msg.sender);
    }

    function providerWithdraw() external {
        euint64 bal = _providerBalance[msg.sender];
        _providerBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_providerBalance[msg.sender]);
        FHE.allow(bal, msg.sender);
    }

    function allowDatasetDetails(uint256 id, address viewer) external {
        require(datasets[id].provider == msg.sender || msg.sender == owner(), "Unauthorized");
        FHE.allow(datasets[id].baseAccessFeeUSD, viewer);
        FHE.allow(datasets[id].perKm2FeeUSD, viewer);
        FHE.allow(datasets[id].totalRevenue, viewer);
        FHE.allow(datasets[id].accessGranted, viewer);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalMarketVolume, viewer);
    }
}
