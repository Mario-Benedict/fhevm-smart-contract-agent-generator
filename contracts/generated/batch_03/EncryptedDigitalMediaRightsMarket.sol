// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedDigitalMediaRightsMarket
/// @notice Digital media licensing marketplace with encrypted royalty rates,
///         private licensing negotiations, and confidential streaming revenue splits.
///         Supports music, film, software, and literary rights.
contract EncryptedDigitalMediaRightsMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum MediaType { MUSIC, FILM_TV, SOFTWARE, LITERARY, PHOTOGRAPHY, GAME_ASSET, PODCAST }
    enum LicenseScope { PERSONAL, COMMERCIAL, ENTERPRISE, EXCLUSIVE, SYNC }

    struct MediaAsset {
        address rightsHolder;
        MediaType mediaType;
        euint64 minimumLicenseFeeUSD;    // encrypted floor price
        euint64 exclusiveLicenseFeeUSD;  // encrypted exclusive rights price
        euint64 royaltyRateBps;          // encrypted ongoing royalty rate
        euint64 streamingRevenueShareBps; // encrypted streaming share
        euint64 totalEarningsUSD;        // encrypted total earnings
        euint64 totalLicensedCount;      // encrypted number of licenses issued
        bytes32 contentHash;             // hash of content identifier (ISRC/ISAN/ISBN)
        uint256 registrationDate;
        bool active;
        bool exclusiveLicensed;
    }

    struct LicenseAgreement {
        uint256 assetId;
        address licensee;
        LicenseScope scope;
        euint64 agreementFeeUSD;         // encrypted agreed license fee
        euint64 advancePaymentUSD;       // encrypted advance against royalties
        euint64 royaltiesAccrued;        // encrypted royalties accrued
        euint64 royaltiesPaid;           // encrypted royalties paid out
        euint64 usageCountEncrypted;     // encrypted usage count/streams
        uint256 licenseStart;
        uint256 licenseEnd;
        bool exclusive;
        bool terminated;
    }

    struct RoyaltyStatement {
        uint256 licenseId;
        euint64 periodRevenueUSD;        // encrypted revenue for period
        euint64 royaltyDueUSD;           // encrypted royalty calculation
        euint64 advanceRecoupedUSD;      // encrypted advance recouped
        euint64 netPayableUSD;           // encrypted net due to rights holder
        uint256 statementPeriodEnd;
        bool paid;
    }

    mapping(uint256 => MediaAsset) private assets;
    mapping(uint256 => LicenseAgreement) private licenses;
    mapping(uint256 => RoyaltyStatement) private statements;
    mapping(address => bool) public isRightsHolder;
    mapping(address => bool) public isLicensingAgent;

    uint256 public assetCount;
    uint256 public licenseCount;
    uint256 public statementCount;
    euint64 private _marketTotalTransactions;
    euint64 private _marketTotalRoyaltiesPaid;

    event AssetRegistered(uint256 indexed assetId, address rightsHolder, MediaType mediaType);
    event LicenseNegotiated(uint256 indexed licenseId, uint256 assetId, address licensee);
    event LicenseSigned(uint256 indexed licenseId);
    event RoyaltyStatementIssued(uint256 indexed statementId, uint256 licenseId);
    event RoyaltyPaid(uint256 indexed statementId, address rightsHolder);

    constructor() Ownable(msg.sender) {
        _marketTotalTransactions = FHE.asEuint64(0);
        _marketTotalRoyaltiesPaid = FHE.asEuint64(0);
        FHE.allowThis(_marketTotalTransactions);
        FHE.allowThis(_marketTotalRoyaltiesPaid);
        isLicensingAgent[msg.sender] = true;
    }

    function registerAsset(
        MediaType mediaType,
        externalEuint64 encMinFee, bytes calldata mfProof,
        externalEuint64 encExclusiveFee, bytes calldata efProof,
        externalEuint64 encRoyaltyRate, bytes calldata rrProof,
        externalEuint64 encStreamShare, bytes calldata ssProof,
        bytes32 contentHash
    ) external returns (uint256 assetId) {
        assetId = assetCount++;
        MediaAsset storage ma = assets[assetId];
        ma.rightsHolder = msg.sender;
        ma.mediaType = mediaType;
        ma.minimumLicenseFeeUSD = FHE.fromExternal(encMinFee, mfProof);
        ma.exclusiveLicenseFeeUSD = FHE.fromExternal(encExclusiveFee, efProof);
        ma.royaltyRateBps = FHE.fromExternal(encRoyaltyRate, rrProof);
        ma.streamingRevenueShareBps = FHE.fromExternal(encStreamShare, ssProof);
        ma.totalEarningsUSD = FHE.asEuint64(0);
        ma.totalLicensedCount = FHE.asEuint64(0);
        ma.contentHash = contentHash;
        ma.registrationDate = block.timestamp;
        ma.active = true;
        isRightsHolder[msg.sender] = true;
        FHE.allowThis(ma.minimumLicenseFeeUSD);
        FHE.allow(ma.minimumLicenseFeeUSD, msg.sender);
        FHE.allowThis(ma.exclusiveLicenseFeeUSD);
        FHE.allow(ma.exclusiveLicenseFeeUSD, msg.sender);
        FHE.allowThis(ma.royaltyRateBps);
        FHE.allow(ma.royaltyRateBps, msg.sender);
        FHE.allowThis(ma.totalEarningsUSD);
        FHE.allow(ma.totalEarningsUSD, msg.sender);
        FHE.allowThis(ma.totalLicensedCount);
        emit AssetRegistered(assetId, msg.sender, mediaType);
    }

    function negotiateLicense(
        uint256 assetId,
        LicenseScope scope,
        externalEuint64 encOfferedFee, bytes calldata ofProof,
        externalEuint64 encAdvance, bytes calldata aProof,
        uint256 licenseStart, uint256 licenseEnd
    ) external nonReentrant returns (uint256 licenseId) {
        MediaAsset storage ma = assets[assetId];
        require(ma.active, "Asset not available");
        require(!ma.exclusiveLicensed || scope != LicenseScope.EXCLUSIVE, "Already exclusively licensed");
        euint64 offeredFee = FHE.fromExternal(encOfferedFee, ofProof);
        euint64 advance = FHE.fromExternal(encAdvance, aProof);
        // Check offered fee meets minimum
        ebool meetsMinimum = FHE.ge(offeredFee, ma.minimumLicenseFeeUSD);
        euint64 agreedFee = FHE.select(meetsMinimum, offeredFee, ma.minimumLicenseFeeUSD);
        licenseId = licenseCount++;
        LicenseAgreement storage la = licenses[licenseId];
        la.assetId = assetId;
        la.licensee = msg.sender;
        la.scope = scope;
        la.agreementFeeUSD = agreedFee;
        la.advancePaymentUSD = advance;
        la.royaltiesAccrued = FHE.asEuint64(0);
        la.royaltiesPaid = FHE.asEuint64(0);
        la.usageCountEncrypted = FHE.asEuint64(0);
        la.licenseStart = licenseStart;
        la.licenseEnd = licenseEnd;
        la.exclusive = (scope == LicenseScope.EXCLUSIVE);
        ma.totalLicensedCount = FHE.add(ma.totalLicensedCount, FHE.asEuint64(1));
        ma.totalEarningsUSD = FHE.add(ma.totalEarningsUSD, agreedFee);
        if (scope == LicenseScope.EXCLUSIVE) ma.exclusiveLicensed = true;
        _marketTotalTransactions = FHE.add(_marketTotalTransactions, agreedFee);
        FHE.allowThis(la.agreementFeeUSD);
        FHE.allow(la.agreementFeeUSD, msg.sender);
        FHE.allow(la.agreementFeeUSD, ma.rightsHolder);
        FHE.allowThis(la.advancePaymentUSD);
        FHE.allow(la.advancePaymentUSD, ma.rightsHolder);
        FHE.allowThis(la.royaltiesAccrued);
        FHE.allow(la.royaltiesAccrued, ma.rightsHolder);
        FHE.allowThis(la.usageCountEncrypted);
        FHE.allow(la.usageCountEncrypted, msg.sender);
        FHE.allowThis(ma.totalEarningsUSD);
        FHE.allow(ma.totalEarningsUSD, ma.rightsHolder);
        FHE.allowThis(_marketTotalTransactions);
        emit LicenseNegotiated(licenseId, assetId, msg.sender);
    }

    function reportUsage(
        uint256 licenseId,
        externalEuint64 encUsageCount, bytes calldata ucProof,
        externalEuint64 encRevenue, bytes calldata revProof
    ) external {
        LicenseAgreement storage la = licenses[licenseId];
        MediaAsset storage ma = assets[la.assetId];
        require(msg.sender == la.licensee || isLicensingAgent[msg.sender], "Unauthorized");
        euint64 usageCount = FHE.fromExternal(encUsageCount, ucProof);
        euint64 revenue = FHE.fromExternal(encRevenue, revProof);
        la.usageCountEncrypted = FHE.add(la.usageCountEncrypted, usageCount);
        // Calculate royalties
        euint64 royaltyDue = FHE.div(FHE.mul(revenue, ma.royaltyRateBps), 10000);
        la.royaltiesAccrued = FHE.add(la.royaltiesAccrued, royaltyDue);
        FHE.allowThis(la.usageCountEncrypted);
        FHE.allow(la.usageCountEncrypted, la.licensee);
        FHE.allowThis(la.royaltiesAccrued);
        FHE.allow(la.royaltiesAccrued, ma.rightsHolder);
        FHE.allow(la.royaltiesAccrued, la.licensee);
    }

    function issueRoyaltyStatement(
        uint256 licenseId,
        uint256 periodEnd
    ) external returns (uint256 statementId) {
        require(isLicensingAgent[msg.sender] || isRightsHolder[msg.sender], "Unauthorized");
        LicenseAgreement storage la = licenses[licenseId];
        MediaAsset storage ma = assets[la.assetId];
        euint64 royaltyDue = FHE.sub(la.royaltiesAccrued, la.royaltiesPaid);
        // Recoup advance first
        euint64 recouped = FHE.select(FHE.le(la.advancePaymentUSD, royaltyDue),
            la.advancePaymentUSD, royaltyDue);
        euint64 netPayable = FHE.sub(royaltyDue, recouped);
        statementId = statementCount++;
        statements[statementId] = RoyaltyStatement({
            licenseId: licenseId, periodRevenueUSD: FHE.asEuint64(0),
            royaltyDueUSD: royaltyDue, advanceRecoupedUSD: recouped,
            netPayableUSD: netPayable, statementPeriodEnd: periodEnd, paid: false
        });
        FHE.allowThis(statements[statementId].royaltyDueUSD);
        FHE.allow(statements[statementId].royaltyDueUSD, ma.rightsHolder);
        FHE.allow(statements[statementId].royaltyDueUSD, la.licensee);
        FHE.allowThis(statements[statementId].netPayableUSD);
        FHE.allow(statements[statementId].netPayableUSD, ma.rightsHolder);
        emit RoyaltyStatementIssued(statementId, licenseId);
    }

    function payRoyalty(uint256 statementId) external nonReentrant {
        RoyaltyStatement storage rs = statements[statementId];
        LicenseAgreement storage la = licenses[rs.licenseId];
        MediaAsset storage ma = assets[la.assetId];
        require(msg.sender == la.licensee, "Not licensee");
        require(!rs.paid, "Already paid");
        rs.paid = true;
        la.royaltiesPaid = FHE.add(la.royaltiesPaid, rs.royaltyDueUSD);
        _marketTotalRoyaltiesPaid = FHE.add(_marketTotalRoyaltiesPaid, rs.netPayableUSD);
        FHE.allowThis(la.royaltiesPaid);
        FHE.allowThis(_marketTotalRoyaltiesPaid);
        FHE.allowTransient(rs.netPayableUSD, ma.rightsHolder);
        emit RoyaltyPaid(statementId, ma.rightsHolder);
    }

    function addLicensingAgent(address la) external onlyOwner { isLicensingAgent[la] = true; }
    function allowMarketStats(address analyst) external onlyOwner {
        FHE.allow(_marketTotalTransactions, analyst);
        FHE.allow(_marketTotalRoyaltiesPaid, analyst);
    }
}
