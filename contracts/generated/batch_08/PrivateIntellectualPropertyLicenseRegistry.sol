// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateIntellectualPropertyLicenseRegistry
/// @notice Encrypted IP licensing registry: hidden royalty rates, private revenue
///         thresholds, confidential sublicensee identities, and encrypted
///         patent infringement dispute deposits.
contract PrivateIntellectualPropertyLicenseRegistry is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum IPType { Patent, Trademark, Copyright, TradeSecret, SoftwareLicense, DataLicense }
    enum LicenseScope { Exclusive, NonExclusive, Sublicensable, WorldwideExclusive }

    struct IPAsset {
        address owner;
        IPType ipType;
        string assetRef;
        string jurisdiction;
        euint64 valuationUSD;          // encrypted valuation
        euint64 royaltyRateBps;        // encrypted royalty rate
        euint64 minimumGuaranteedUSD;  // encrypted MG
        euint64 totalRoyaltiesEarned;  // encrypted cumulative royalties
        bool registered;
    }

    struct License {
        uint256 assetId;
        address licensee;
        LicenseScope scope;
        euint64 upfrontFeeUSD;         // encrypted upfront fee
        euint64 royaltyRateOverrideBps;// encrypted override rate (if negotiated)
        euint64 revenueShareBps;       // encrypted revenue share
        euint64 royaltiesPaidUSD;      // encrypted royalties paid
        uint256 grantedAt;
        uint256 expiryDate;
        bool active;
    }

    struct DisputeDeposit {
        uint256 assetId;
        address disputant;
        euint64 depositAmountUSD;      // encrypted dispute deposit
        string  claimRef;
        uint256 filedAt;
        bool resolved;
    }

    mapping(uint256 => IPAsset) private assets;
    mapping(uint256 => License) private licenses;
    mapping(uint256 => DisputeDeposit) private disputes;
    mapping(address => bool) public isIPRegistrar;

    uint256 public assetCount;
    uint256 public licenseCount;
    uint256 public disputeCount;
    euint64 private _totalIPValueUSD;
    euint64 private _totalRoyaltiesUSD;

    event IPAssetRegistered(uint256 indexed id, IPType ipType, address owner);
    event LicenseGranted(uint256 indexed id, uint256 assetId, address licensee, LicenseScope scope);
    event RoyaltyPaid(uint256 indexed licenseId, uint256 paidAt);
    event DisputeFiled(uint256 indexed disputeId, uint256 assetId);

    modifier onlyIPRegistrar() {
        require(isIPRegistrar[msg.sender] || msg.sender == owner(), "Not IP registrar");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalIPValueUSD = FHE.asEuint64(0);
        _totalRoyaltiesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalIPValueUSD);
        FHE.allowThis(_totalRoyaltiesUSD);
        isIPRegistrar[msg.sender] = true;
    }

    function addIPRegistrar(address r) external onlyOwner { isIPRegistrar[r] = true; }

    function registerIPAsset(
        IPType ipType, string calldata assetRef, string calldata jurisdiction,
        externalEuint64 encValuation, bytes calldata vProof,
        externalEuint64 encRoyaltyRate, bytes calldata rrProof,
        externalEuint64 encMG, bytes calldata mgProof
    ) external returns (uint256 id) {
        euint64 valuation   = FHE.fromExternal(encValuation, vProof);
        euint64 royaltyRate = FHE.fromExternal(encRoyaltyRate, rrProof);
        euint64 mg          = FHE.fromExternal(encMG, mgProof);
        id = assetCount++;
        assets[id].owner = msg.sender;
        assets[id].ipType = ipType;
        assets[id].assetRef = assetRef;
        assets[id].jurisdiction = jurisdiction;
        assets[id].valuationUSD = valuation;
        assets[id].royaltyRateBps = royaltyRate;
        assets[id].minimumGuaranteedUSD = mg;
        assets[id].totalRoyaltiesEarned = FHE.asEuint64(0);
        assets[id].registered = true;
        _totalIPValueUSD = FHE.add(_totalIPValueUSD, valuation);
        FHE.allowThis(assets[id].valuationUSD); FHE.allow(assets[id].valuationUSD, msg.sender);
        FHE.allowThis(assets[id].royaltyRateBps); FHE.allow(assets[id].royaltyRateBps, msg.sender);
        FHE.allowThis(assets[id].minimumGuaranteedUSD); FHE.allow(assets[id].minimumGuaranteedUSD, msg.sender);
        FHE.allowThis(assets[id].totalRoyaltiesEarned); FHE.allow(assets[id].totalRoyaltiesEarned, msg.sender);
        FHE.allowThis(_totalIPValueUSD);
        emit IPAssetRegistered(id, ipType, msg.sender);
    }

    function grantLicense(
        uint256 assetId, address licensee, LicenseScope scope,
        externalEuint64 encUpfront, bytes calldata uProof,
        externalEuint64 encRoyOverride, bytes calldata roProof,
        externalEuint64 encRevShare, bytes calldata rsProof,
        uint256 durationYears
    ) external nonReentrant returns (uint256 licId) {
        IPAsset storage a = assets[assetId];
        require(a.owner == msg.sender && a.registered, "Not asset owner");
        euint64 upfront    = FHE.fromExternal(encUpfront, uProof);
        euint64 royOverride= FHE.fromExternal(encRoyOverride, roProof);
        euint64 revShare   = FHE.fromExternal(encRevShare, rsProof);
        licId = licenseCount++;
        licenses[licId].assetId = assetId;
        licenses[licId].licensee = licensee;
        licenses[licId].scope = scope;
        licenses[licId].upfrontFeeUSD = upfront;
        licenses[licId].royaltyRateOverrideBps = royOverride;
        licenses[licId].revenueShareBps = revShare;
        licenses[licId].royaltiesPaidUSD = FHE.asEuint64(0);
        licenses[licId].grantedAt = block.timestamp;
        licenses[licId].expiryDate = block.timestamp + durationYears * 365 days;
        licenses[licId].active = true;
        FHE.allowThis(licenses[licId].upfrontFeeUSD); FHE.allow(licenses[licId].upfrontFeeUSD, licensee); FHE.allow(licenses[licId].upfrontFeeUSD, msg.sender);
        FHE.allowThis(licenses[licId].royaltyRateOverrideBps); FHE.allow(licenses[licId].royaltyRateOverrideBps, licensee);
        FHE.allowThis(licenses[licId].revenueShareBps); FHE.allow(licenses[licId].revenueShareBps, licensee);
        FHE.allowThis(licenses[licId].royaltiesPaidUSD); FHE.allow(licenses[licId].royaltiesPaidUSD, msg.sender);
        emit LicenseGranted(licId, assetId, licensee, scope);
    }

    function payRoyalty(uint256 licenseId, externalEuint64 encAmt, bytes calldata proof) external nonReentrant {
        License storage l = licenses[licenseId];
        require(msg.sender == l.licensee && l.active, "Not licensee");
        euint64 amt = FHE.fromExternal(encAmt, proof);
        l.royaltiesPaidUSD = FHE.add(l.royaltiesPaidUSD, amt);
        assets[l.assetId].totalRoyaltiesEarned = FHE.add(assets[l.assetId].totalRoyaltiesEarned, amt);
        _totalRoyaltiesUSD = FHE.add(_totalRoyaltiesUSD, amt);
        FHE.allowThis(l.royaltiesPaidUSD); FHE.allow(l.royaltiesPaidUSD, assets[l.assetId].owner);
        FHE.allowThis(assets[l.assetId].totalRoyaltiesEarned); FHE.allow(assets[l.assetId].totalRoyaltiesEarned, assets[l.assetId].owner);
        FHE.allowThis(_totalRoyaltiesUSD);
        emit RoyaltyPaid(licenseId, block.timestamp);
    }

    function fileDispute(uint256 assetId, string calldata claimRef, externalEuint64 encDeposit, bytes calldata proof) external returns (uint256 disputeId) {
        euint64 deposit = FHE.fromExternal(encDeposit, proof);
        disputeId = disputeCount++;
        disputes[disputeId] = DisputeDeposit({ assetId: assetId, disputant: msg.sender, depositAmountUSD: deposit, claimRef: claimRef, filedAt: block.timestamp, resolved: false });
        FHE.allowThis(disputes[disputeId].depositAmountUSD);
        emit DisputeFiled(disputeId, assetId);
    }

    function allowRegistryStats(address viewer) external onlyOwner {
        FHE.allow(_totalIPValueUSD, viewer); FHE.allow(_totalRoyaltiesUSD, viewer);
    }
}
