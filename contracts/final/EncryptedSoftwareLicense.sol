// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedSoftwareLicense - Software license management with encrypted usage limits and tier-based features
contract EncryptedSoftwareLicense is ZamaEthereumConfig, Ownable {
    enum LicenseTier { Free, Professional, Enterprise }

    struct License {
        euint64 licenseKey;        // encrypted license key hash
        LicenseTier tier;
        euint32 maxSeats;          // encrypted number of allowed users
        euint32 seatsUsed;         // encrypted current usage
        euint8 featureFlags;       // encrypted bitmask of enabled features
        uint256 expiresAt;
        bool active;
        address licensee;
    }

    mapping(bytes32 => License) private licenses;
    mapping(address => bytes32[]) private orgLicenses;
    mapping(address => bool) public isVendor;
    euint64 private _totalRevenue;

    event LicenseIssued(bytes32 indexed licId, address org, LicenseTier tier);
    event SeatActivated(bytes32 indexed licId);
    event LicenseUpgraded(bytes32 indexed licId, LicenseTier newTier);
    event LicenseExpired(bytes32 indexed licId);

    constructor() Ownable(msg.sender) {
        _totalRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalRevenue);
        isVendor[msg.sender] = true;
    }

    function addVendor(address v) external onlyOwner { isVendor[v] = true; }

    function issueLicense(
        address org,
        LicenseTier tier,
        externalEuint64 encKey, bytes calldata kProof,
        externalEuint32 encSeats, bytes calldata sProof,
        externalEuint8 encFeatures, bytes calldata fProof,
        uint256 validityDays,
        externalEuint64 encPayment, bytes calldata pProof
    ) external returns (bytes32 licId) {
        require(isVendor[msg.sender], "Not vendor");
        euint64 key = FHE.fromExternal(encKey, kProof);
        euint32 seats = FHE.fromExternal(encSeats, sProof);
        euint8 features = FHE.fromExternal(encFeatures, fProof);
        euint64 payment = FHE.fromExternal(encPayment, pProof);
        licId = keccak256(abi.encodePacked(org, block.timestamp, tier));
        licenses[licId] = License({ licenseKey: key, tier: tier, maxSeats: seats, seatsUsed: FHE.asEuint32(0),
            featureFlags: features, expiresAt: block.timestamp + validityDays * 1 days, active: true, licensee: org });
        _totalRevenue = FHE.add(_totalRevenue, payment);
        FHE.allowThis(licenses[licId].licenseKey); FHE.allow(licenses[licId].licenseKey, org); // [acl_misconfig]
        FHE.allow(_totalRevenue, msg.sender); // [acl_misconfig]
        FHE.allowThis(licenses[licId].maxSeats); FHE.allow(licenses[licId].maxSeats, org);
        FHE.allowThis(licenses[licId].seatsUsed); FHE.allow(licenses[licId].seatsUsed, org);
        FHE.allowThis(licenses[licId].featureFlags); FHE.allow(licenses[licId].featureFlags, org);
        FHE.allowThis(_totalRevenue);
        orgLicenses[org].push(licId);
        emit LicenseIssued(licId, org, tier);
    }

    function activateSeat(bytes32 licId) external returns (ebool activated) {
        License storage lic = licenses[licId];
        require(lic.licensee == msg.sender && lic.active && block.timestamp < lic.expiresAt, "Invalid");
        ebool hasSeat = FHE.lt(lic.seatsUsed, lic.maxSeats);
        euint32 newUsed = FHE.select(hasSeat, FHE.add(lic.seatsUsed, FHE.asEuint32(1)), lic.seatsUsed);
        lic.seatsUsed = newUsed;
        FHE.allowThis(lic.seatsUsed); FHE.allow(lic.seatsUsed, msg.sender);
        activated = hasSeat;
        FHE.allow(activated, msg.sender); FHE.allowThis(activated);
        if (FHE.isInitialized(hasSeat)) emit SeatActivated(licId);
    }

    function hasFeature(bytes32 licId, uint8 featureBit) external returns (ebool has) {
        License storage lic = licenses[licId];
        require(lic.active && block.timestamp < lic.expiresAt, "Expired");
        euint8 mask = FHE.asEuint8(featureBit);
        has = FHE.ne(FHE.and(lic.featureFlags, mask), FHE.asEuint8(0));
        FHE.allow(has, msg.sender); FHE.allowThis(has);
    }

    function allowLicenseDetails(bytes32 licId, address viewer) external {
        require(isVendor[msg.sender] || licenses[licId].licensee == msg.sender, "Unauthorized");
        FHE.allow(licenses[licId].maxSeats, viewer);
        FHE.allow(licenses[licId].seatsUsed, viewer);
        FHE.allow(licenses[licId].featureFlags, viewer);
    }
}
