// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateSatelliteImageryCommercialLicense
/// @notice Encrypted satellite imagery commercial licensing: hidden resolution pricing tiers,
///         confidential usage volume caps, private government security clearance requirements,
///         and encrypted export control classification scores.
contract PrivateSatelliteImageryCommercialLicense is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ResolutionClass { SubMeter, OneMeter, FiveMeter, TenMeter, ThirtyMeter }
    enum LicenseScope { SingleImage, AreaCoverage, TimeSeries, FullArchive, NearRealTime }

    struct ImageryLicense {
        address provider;
        address licensee;
        ResolutionClass resolution;
        LicenseScope licenseScope;
        string coverageAreaRef;
        euint64 annualLicenseFeeUSD;   // encrypted annual fee
        euint64 usageVolumeCapSqKm;    // encrypted coverage cap
        euint64 usedVolumeSqKm;        // encrypted used volume
        euint16 exportControlScore;    // encrypted export compliance score
        euint8  securityClearanceLevel;// encrypted security clearance required
        uint256 licenseStart;
        uint256 licenseEnd;
        bool active;
    }

    mapping(uint256 => ImageryLicense) private licenses;
    mapping(address => bool) public isImageryProvider;
    mapping(address => bool) public isExportControlAuthority;

    uint256 public licenseCount;
    euint64 private _totalLicenseRevenueUSD;
    euint64 private _totalVolumeDeliveredSqKm;

    event LicenseIssued(uint256 indexed id, ResolutionClass resolution, LicenseScope scope);
    event VolumeUsed(uint256 indexed licenseId, uint256 usedAt);
    event LicenseRevoked(uint256 indexed licenseId);

    modifier onlyImageryProvider() {
        require(isImageryProvider[msg.sender] || msg.sender == owner(), "Not imagery provider");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalLicenseRevenueUSD = FHE.asEuint64(0);
        _totalVolumeDeliveredSqKm = FHE.asEuint64(0);
        FHE.allowThis(_totalLicenseRevenueUSD);
        FHE.allowThis(_totalVolumeDeliveredSqKm);
        isImageryProvider[msg.sender] = true;
        isExportControlAuthority[msg.sender] = true;
    }

    function addProvider(address p) external onlyOwner { isImageryProvider[p] = true; }
    function addExportAuthority(address a) external onlyOwner { isExportControlAuthority[a] = true; }

    function issueLicense(
        address licensee, ResolutionClass resolution, LicenseScope scope,
        string calldata coverageAreaRef,
        externalEuint64 encFee, bytes calldata fProof,
        externalEuint64 encVolumeCap, bytes calldata vcProof,
        externalEuint16 encExportScore, bytes calldata esProof,
        externalEuint8 encSecClearance, bytes calldata scProof,
        uint256 durationDays
    ) external onlyImageryProvider returns (uint256 id) {
        euint64 fee = FHE.fromExternal(encFee, fProof);
        euint64 volumeCap = FHE.fromExternal(encVolumeCap, vcProof);
        euint16 exportScore = FHE.fromExternal(encExportScore, esProof);
        euint8 secClearance = FHE.fromExternal(encSecClearance, scProof);
        id = licenseCount++;
        ImageryLicense storage _s0 = licenses[id];
        _s0.provider = msg.sender;
        _s0.licensee = licensee;
        _s0.resolution = resolution;
        _s0.licenseScope = scope;
        _s0.coverageAreaRef = coverageAreaRef;
        _s0.annualLicenseFeeUSD = fee;
        _s0.usageVolumeCapSqKm = volumeCap;
        _s0.usedVolumeSqKm = FHE.asEuint64(0);
        _s0.exportControlScore = exportScore;
        _s0.securityClearanceLevel = secClearance;
        _s0.licenseStart = block.timestamp;
        _s0.licenseEnd = block.timestamp + durationDays * 1 days;
        _s0.active = true;
        _totalLicenseRevenueUSD = FHE.add(_totalLicenseRevenueUSD, fee);
        FHE.allowThis(licenses[id].annualLicenseFeeUSD); FHE.allow(licenses[id].annualLicenseFeeUSD, licensee); FHE.allow(licenses[id].annualLicenseFeeUSD, msg.sender);
        FHE.allowThis(licenses[id].usageVolumeCapSqKm); FHE.allow(licenses[id].usageVolumeCapSqKm, licensee);
        FHE.allowThis(licenses[id].usedVolumeSqKm); FHE.allow(licenses[id].usedVolumeSqKm, licensee);
        FHE.allowThis(licenses[id].exportControlScore);
        FHE.allowThis(licenses[id].securityClearanceLevel);
        FHE.allowThis(_totalLicenseRevenueUSD);
        emit LicenseIssued(id, resolution, scope);
    }

    function recordVolumeUsage(
        uint256 licenseId,
        externalEuint64 encUsedSqKm, bytes calldata proof
    ) external nonReentrant {
        ImageryLicense storage l = licenses[licenseId];
        require(msg.sender == l.licensee || isImageryProvider[msg.sender], "Not authorized");
        require(l.active, "License not active");
        euint64 usedSqKm = FHE.fromExternal(encUsedSqKm, proof);
        ebool withinCap = FHE.le(FHE.add(l.usedVolumeSqKm, usedSqKm), l.usageVolumeCapSqKm);
        euint64 effectiveUsage = FHE.select(withinCap, usedSqKm, FHE.asEuint64(0));
        l.usedVolumeSqKm = FHE.add(l.usedVolumeSqKm, effectiveUsage);
        _totalVolumeDeliveredSqKm = FHE.add(_totalVolumeDeliveredSqKm, effectiveUsage);
        FHE.allowThis(l.usedVolumeSqKm); FHE.allow(l.usedVolumeSqKm, l.licensee); FHE.allow(l.usedVolumeSqKm, l.provider);
        FHE.allowThis(_totalVolumeDeliveredSqKm);
        emit VolumeUsed(licenseId, block.timestamp);
    }

    function revokeLicense(uint256 licenseId) external onlyImageryProvider {
        licenses[licenseId].active = false;
        emit LicenseRevoked(licenseId);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalLicenseRevenueUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalLicenseRevenueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalVolumeDeliveredSqKm, msg.sender); // [acl_misconfig]
        FHE.allow(_totalVolumeDeliveredSqKm, viewer);
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