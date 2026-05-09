// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedTimberHarvestLicensing
/// @title Forestry commission timber harvest licenses: encrypted stumpage fees,
///        encrypted board-feet volumes, and encrypted sustainable yield metrics.
contract EncryptedTimberHarvestLicensing is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum TreeSpecies { DouglasFir, Spruce, Pine, Hemlock, RedCedar, Teak, Mahogany }
    enum HarvestMethod { Clearcutting, SelectiveCut, SeedTree, Shelterwood, PatchCut }
    enum LicenseStatus { Pending, Active, Suspended, Revoked, Expired }

    struct TimberLicense {
        address licensee;
        string forestId;
        string jurisdictionCode;
        TreeSpecies primarySpecies;
        HarvestMethod method;
        euint64 authorizedVolumeBF;      // encrypted authorized board-feet
        euint64 harvestedVolumeBF;       // encrypted volume harvested to date
        euint64 stumpageFeePerMBF;       // encrypted stumpage fee per thousand BF
        euint64 totalFeesAccruedUSD;     // encrypted fees owed
        euint32 sustainableYieldRatioBps;// encrypted sustainable yield compliance
        uint256 harvestSeason;           // season end timestamp
        LicenseStatus status;
    }

    struct HarvestReport {
        uint256 licenseId;
        euint32 logsHarvested;           // encrypted log count
        euint64 volumeBF;                // encrypted board-feet harvested
        euint64 feeDueUSD;               // encrypted fee due
        string cutBlock;
        uint256 reportDate;
        bool paid;
    }

    mapping(uint256 => TimberLicense) private licenses;
    mapping(uint256 => HarvestReport[]) private reports;
    mapping(address => bool) public isForestryCommission;
    mapping(address => bool) public isLicensee;

    uint256 public licenseCount;
    euint64 private _totalVolumeHarvestedBF;
    euint64 private _totalFeesCollectedUSD;

    event LicenseGranted(uint256 indexed id, string forestId, TreeSpecies species);
    event HarvestReported(uint256 indexed licenseId, uint256 reportIndex);
    event FeePaid(uint256 indexed licenseId, uint256 reportIndex);
    event LicenseSuspended(uint256 indexed id, string reason);

    modifier onlyCommission() {
        require(isForestryCommission[msg.sender] || msg.sender == owner(), "Not forestry commission");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalVolumeHarvestedBF = FHE.asEuint64(0);
        _totalFeesCollectedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalVolumeHarvestedBF);
        FHE.allowThis(_totalFeesCollectedUSD);
        isForestryCommission[msg.sender] = true;
    }

    function addCommission(address c) external onlyOwner { isForestryCommission[c] = true; }
    function addLicensee(address l) external onlyOwner { isLicensee[l] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function grantLicense(
        address licensee, string calldata forestId, string calldata jurisdiction,
        TreeSpecies species, HarvestMethod method,
        externalEuint64 encVolume, bytes calldata vProof,
        externalEuint64 encStumpage, bytes calldata sProof,
        externalEuint32 encYield, bytes calldata yProof,
        uint256 seasonDays
    ) external onlyCommission whenNotPaused returns (uint256 id) {
        euint64 volume = FHE.fromExternal(encVolume, vProof);
        euint64 stumpage = FHE.fromExternal(encStumpage, sProof);
        euint32 yield = FHE.fromExternal(encYield, yProof);
        id = licenseCount++;
        TimberLicense storage _s0 = licenses[id];
        _s0.licensee = licensee;
        _s0.forestId = forestId;
        _s0.jurisdictionCode = jurisdiction;
        _s0.primarySpecies = species;
        _s0.method = method;
        _s0.authorizedVolumeBF = volume;
        _s0.harvestedVolumeBF = FHE.asEuint64(0);
        _s0.stumpageFeePerMBF = stumpage;
        _s0.totalFeesAccruedUSD = FHE.asEuint64(0);
        _s0.sustainableYieldRatioBps = yield;
        _s0.harvestSeason = block.timestamp + seasonDays * 1 days;
        _s0.status = LicenseStatus.Active;
        FHE.allowThis(licenses[id].authorizedVolumeBF); FHE.allow(licenses[id].authorizedVolumeBF, licensee);
        FHE.allowThis(licenses[id].harvestedVolumeBF); FHE.allow(licenses[id].harvestedVolumeBF, licensee);
        FHE.allowThis(licenses[id].stumpageFeePerMBF); FHE.allow(licenses[id].stumpageFeePerMBF, licensee);
        FHE.allowThis(licenses[id].totalFeesAccruedUSD); FHE.allow(licenses[id].totalFeesAccruedUSD, licensee);
        FHE.allowThis(licenses[id].sustainableYieldRatioBps);
        emit LicenseGranted(id, forestId, species);
    }

    function reportHarvest(
        uint256 licenseId, string calldata cutBlock,
        externalEuint32 encLogs, bytes calldata logProof,
        externalEuint64 encVolume, bytes calldata vProof
    ) external nonReentrant {
        TimberLicense storage l = licenses[licenseId];
        require(l.licensee == msg.sender && l.status == LicenseStatus.Active, "Not authorized");
        require(block.timestamp < l.harvestSeason, "Season ended");
        euint32 logs = FHE.fromExternal(encLogs, logProof);
        euint64 volume = FHE.fromExternal(encVolume, vProof);
        // Clamp to authorized volume
        euint64 remaining = FHE.sub(l.authorizedVolumeBF, l.harvestedVolumeBF);
        ebool withinQuota = FHE.le(volume, remaining);
        euint64 actualVolume = FHE.select(withinQuota, volume, remaining);
        l.harvestedVolumeBF = FHE.add(l.harvestedVolumeBF, actualVolume);
        euint64 feeDue = FHE.mul(actualVolume, l.stumpageFeePerMBF);
        l.totalFeesAccruedUSD = FHE.add(l.totalFeesAccruedUSD, feeDue);
        _totalVolumeHarvestedBF = FHE.add(_totalVolumeHarvestedBF, actualVolume);
        reports[licenseId].push(HarvestReport({
            licenseId: licenseId, logsHarvested: logs, volumeBF: actualVolume,
            feeDueUSD: feeDue, cutBlock: cutBlock, reportDate: block.timestamp, paid: false
        }));
        FHE.allowThis(l.harvestedVolumeBF); FHE.allow(l.harvestedVolumeBF, msg.sender);
        FHE.allowThis(l.totalFeesAccruedUSD); FHE.allow(l.totalFeesAccruedUSD, msg.sender);
        FHE.allowThis(feeDue); FHE.allow(feeDue, owner());
        FHE.allowThis(_totalVolumeHarvestedBF);
        emit HarvestReported(licenseId, reports[licenseId].length - 1);
    }

    function confirmPayment(uint256 licenseId, uint256 reportIndex) external onlyCommission {
        HarvestReport storage r = reports[licenseId][reportIndex];
        require(!r.paid, "Already paid");
        r.paid = true;
        _totalFeesCollectedUSD = FHE.add(_totalFeesCollectedUSD, r.feeDueUSD);
        FHE.allowThis(_totalFeesCollectedUSD);
        emit FeePaid(licenseId, reportIndex);
    }

    function suspendLicense(uint256 licenseId, string calldata reason) external onlyCommission {
        licenses[licenseId].status = LicenseStatus.Suspended;
        emit LicenseSuspended(licenseId, reason);
    }

    function allowForestryStats(address viewer) external onlyOwner {
        FHE.allow(_totalVolumeHarvestedBF, viewer);
        FHE.allow(_totalFeesCollectedUSD, viewer);
    }
}
