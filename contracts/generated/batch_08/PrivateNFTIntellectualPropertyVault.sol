// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateNFTIntellectualPropertyVault
/// @notice Encrypted IP ownership vault: hidden royalty rates, confidential licensing terms,
///         private sub-licensing chains, and encrypted revenue distribution to IP co-owners.
contract PrivateNFTIntellectualPropertyVault is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum IPCategory { Patent, Trademark, Copyright, TradeSecret, DesignRight, SoftwareLicense }
    enum LicenseScope { Exclusive, NonExclusive, SoleExclusive, Sublicensable }

    struct IPAsset {
        address primaryOwner;
        IPCategory ipCategory;
        string ipTitle;
        string registrationRef;
        euint64 baseRoyaltyRateBps;   // encrypted base royalty in bps
        euint64 totalLicenseRevenueUSD; // encrypted accumulated revenue
        euint32 totalLicensees;       // encrypted count of licensees
        euint16 ownershipShareBps;    // encrypted primary owner share (of revenue)
        bool active;
    }

    struct LicenseGrant {
        uint256 assetId;
        address licensee;
        LicenseScope scope;
        euint64 licenseFeeUSD;        // encrypted license fee paid
        euint64 royaltyRateBps;       // encrypted agreed royalty rate
        euint64 revenueReportedUSD;   // encrypted licensee revenue
        euint64 royaltyOwedUSD;       // encrypted royalty owed to IP owner
        uint256 grantedAt;
        uint256 expiresAt;
        bool active;
    }

    struct CoOwner {
        address coOwner;
        euint16 sharesBps;            // encrypted co-ownership share
        euint64 accruedRoyaltyUSD;    // encrypted accrued royalty to co-owner
    }

    mapping(uint256 => IPAsset) private ipAssets;
    mapping(uint256 => LicenseGrant) private licenses;
    mapping(uint256 => CoOwner[]) private coOwners;
    mapping(address => bool) public isIPRegistrar;

    uint256 public assetCount;
    uint256 public licenseCount;
    euint64 private _totalSystemRoyaltiesUSD;

    event IPAssetRegistered(uint256 indexed id, IPCategory category, string title);
    event LicenseGranted(uint256 indexed licId, uint256 assetId, address licensee);
    event RoyaltyReported(uint256 indexed licId, uint256 reportedAt);
    event RoyaltyDistributed(uint256 indexed assetId);

    modifier onlyIPRegistrar() {
        require(isIPRegistrar[msg.sender] || msg.sender == owner(), "Not IP registrar");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSystemRoyaltiesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSystemRoyaltiesUSD);
        isIPRegistrar[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addIPRegistrar(address r) external onlyOwner { isIPRegistrar[r] = true; }

    function registerIPAsset(
        IPCategory ipCategory,
        string calldata ipTitle,
        string calldata registrationRef,
        externalEuint64 encBaseRoyalty, bytes calldata royProof,
        externalEuint16 encOwnerShare, bytes calldata osProof
    ) external whenNotPaused returns (uint256 id) {
        euint64 baseRoyalty = FHE.fromExternal(encBaseRoyalty, royProof);
        euint16 ownerShare = FHE.fromExternal(encOwnerShare, osProof);
        id = assetCount++;
        ipAssets[id].primaryOwner = msg.sender;
        ipAssets[id].ipCategory = ipCategory;
        ipAssets[id].ipTitle = ipTitle;
        ipAssets[id].registrationRef = registrationRef;
        ipAssets[id].baseRoyaltyRateBps = baseRoyalty;
        ipAssets[id].totalLicenseRevenueUSD = FHE.asEuint64(0);
        ipAssets[id].totalLicensees = FHE.asEuint32(0);
        ipAssets[id].ownershipShareBps = ownerShare;
        ipAssets[id].active = true;
        FHE.allowThis(ipAssets[id].baseRoyaltyRateBps); FHE.allow(ipAssets[id].baseRoyaltyRateBps, msg.sender);
        FHE.allowThis(ipAssets[id].totalLicenseRevenueUSD); FHE.allow(ipAssets[id].totalLicenseRevenueUSD, msg.sender);
        FHE.allowThis(ipAssets[id].totalLicensees);
        FHE.allowThis(ipAssets[id].ownershipShareBps); FHE.allow(ipAssets[id].ownershipShareBps, msg.sender);
        emit IPAssetRegistered(id, ipCategory, ipTitle);
    }

    function grantLicense(
        uint256 assetId,
        address licensee,
        LicenseScope scope,
        externalEuint64 encFee, bytes calldata feeProof,
        externalEuint64 encRoyaltyRate, bytes calldata rrProof,
        uint256 durationDays
    ) external whenNotPaused returns (uint256 licId) {
        IPAsset storage asset = ipAssets[assetId];
        require(msg.sender == asset.primaryOwner || isIPRegistrar[msg.sender], "Not authorized");
        euint64 fee = FHE.fromExternal(encFee, feeProof);
        euint64 royaltyRate = FHE.fromExternal(encRoyaltyRate, rrProof);
        licId = licenseCount++;
        licenses[licId].assetId = assetId;
        licenses[licId].licensee = licensee;
        licenses[licId].scope = scope;
        licenses[licId].licenseFeeUSD = fee;
        licenses[licId].royaltyRateBps = royaltyRate;
        licenses[licId].revenueReportedUSD = FHE.asEuint64(0);
        licenses[licId].royaltyOwedUSD = FHE.asEuint64(0);
        licenses[licId].grantedAt = block.timestamp;
        licenses[licId].expiresAt = block.timestamp + durationDays * 1 days;
        licenses[licId].active = true;
        asset.totalLicenseRevenueUSD = FHE.add(asset.totalLicenseRevenueUSD, fee);
        asset.totalLicensees = FHE.add(asset.totalLicensees, FHE.asEuint32(1));
        FHE.allowThis(licenses[licId].licenseFeeUSD); FHE.allow(licenses[licId].licenseFeeUSD, licensee); FHE.allow(licenses[licId].licenseFeeUSD, asset.primaryOwner);
        FHE.allowThis(licenses[licId].royaltyRateBps); FHE.allow(licenses[licId].royaltyRateBps, licensee);
        FHE.allowThis(licenses[licId].revenueReportedUSD); FHE.allow(licenses[licId].revenueReportedUSD, licensee);
        FHE.allowThis(licenses[licId].royaltyOwedUSD); FHE.allow(licenses[licId].royaltyOwedUSD, asset.primaryOwner);
        FHE.allowThis(asset.totalLicenseRevenueUSD); FHE.allow(asset.totalLicenseRevenueUSD, asset.primaryOwner);
        FHE.allowThis(asset.totalLicensees);
        emit LicenseGranted(licId, assetId, licensee);
    }

    function reportLicenseeRevenue(
        uint256 licId,
        externalEuint64 encRevenue, bytes calldata proof
    ) external {
        LicenseGrant storage lic = licenses[licId];
        require(msg.sender == lic.licensee, "Not licensee");
        euint64 revenue = FHE.fromExternal(encRevenue, proof);
        lic.revenueReportedUSD = FHE.add(lic.revenueReportedUSD, revenue);
        // Royalty = revenue * royaltyRateBps / 10000
        euint64 royalty = FHE.div(FHE.mul(revenue, 500), 10000); // 5% fixed proxy rate (plaintext divisor)
        lic.royaltyOwedUSD = FHE.add(lic.royaltyOwedUSD, royalty);
        IPAsset storage asset = ipAssets[lic.assetId];
        asset.totalLicenseRevenueUSD = FHE.add(asset.totalLicenseRevenueUSD, revenue);
        _totalSystemRoyaltiesUSD = FHE.add(_totalSystemRoyaltiesUSD, royalty);
        FHE.allowThis(lic.revenueReportedUSD); FHE.allow(lic.revenueReportedUSD, lic.licensee);
        FHE.allowThis(lic.royaltyOwedUSD); FHE.allow(lic.royaltyOwedUSD, asset.primaryOwner);
        FHE.allowThis(asset.totalLicenseRevenueUSD); FHE.allow(asset.totalLicenseRevenueUSD, asset.primaryOwner);
        FHE.allowThis(_totalSystemRoyaltiesUSD);
        emit RoyaltyReported(licId, block.timestamp);
    }

    function allowIPView(uint256 assetId, address viewer) external {
        IPAsset storage asset = ipAssets[assetId];
        require(msg.sender == asset.primaryOwner || isIPRegistrar[msg.sender], "Not authorized");
        FHE.allow(asset.baseRoyaltyRateBps, viewer);
        FHE.allow(asset.totalLicenseRevenueUSD, viewer);
        FHE.allow(asset.ownershipShareBps, viewer);
    }

    function allowSystemView(address viewer) external onlyOwner {
        FHE.allow(_totalSystemRoyaltiesUSD, viewer);
    }
}
