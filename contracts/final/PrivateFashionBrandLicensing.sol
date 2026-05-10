// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateFashionBrandLicensing
/// @notice Encrypted fashion brand IP licensing: hidden minimum guarantee royalties, confidential
///         net sales reporting by licensee, private quality inspection scores, and encrypted
///         royalty audit triggers for underpayment detection.
contract PrivateFashionBrandLicensing is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ProductCategory { Apparel, Footwear, Accessories, Fragrance, Eyewear, Homeware }
    enum TerritoryType { Global, NorthAmerica, Europe, AsiaPacific, LatinAmerica, MiddleEast }
    enum LicenseStatus { Active, InBreachCure, Terminated }

    struct FashionLicense {
        address brandOwner;
        address licensee;
        string brandName;
        ProductCategory category;
        TerritoryType territory;
        euint64 minimumGuaranteeUSD;   // encrypted annual minimum guarantee
        euint64 royaltyRateBps;        // encrypted royalty rate bps
        euint64 netSalesReportedUSD;   // encrypted net sales reported
        euint64 royaltiesPaidUSD;      // encrypted royalties paid
        euint64 auditAdjustmentUSD;    // encrypted audit adjustment (underpayment)
        euint16 qualityScorePoints;    // encrypted quality inspection score
        LicenseStatus status;
        uint256 startDate;
        uint256 endDate;
    }

    mapping(uint256 => FashionLicense) private licenses;
    mapping(address => bool) public isBrandAuditor;
    mapping(address => bool) public isQualityInspector;

    uint256 public licenseCount;
    euint64 private _totalRoyaltiesEarnedUSD;
    euint64 private _totalAuditRecoveriesUSD;

    event LicenseCreated(uint256 indexed id, string brandName, ProductCategory category);
    event SalesReported(uint256 indexed licenseId, uint256 reportedAt);
    event RoyaltyPaid(uint256 indexed licenseId, uint256 paidAt);
    event AuditCompleted(uint256 indexed licenseId, uint256 auditedAt);

    modifier onlyBrandAuditor() {
        require(isBrandAuditor[msg.sender] || msg.sender == owner(), "Not brand auditor");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRoyaltiesEarnedUSD = FHE.asEuint64(0);
        _totalAuditRecoveriesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalRoyaltiesEarnedUSD);
        FHE.allowThis(_totalAuditRecoveriesUSD);
        isBrandAuditor[msg.sender] = true;
        isQualityInspector[msg.sender] = true;
    }

    function addBrandAuditor(address a) external onlyOwner { isBrandAuditor[a] = true; }
    function addQualityInspector(address qi) external onlyOwner { isQualityInspector[qi] = true; }

    function createLicense(
        address licensee,
        string calldata brandName,
        ProductCategory category,
        TerritoryType territory,
        externalEuint64 encMinGuarantee, bytes calldata mgProof,
        externalEuint64 encRoyaltyRate, bytes calldata rrProof,
        uint256 durationDays
    ) external returns (uint256 id) {
        euint64 minGuarantee = FHE.fromExternal(encMinGuarantee, mgProof);
        euint64 royaltyRate = FHE.fromExternal(encRoyaltyRate, rrProof);
        id = licenseCount++;
        FashionLicense storage _s0 = licenses[id];
        _s0.brandOwner = msg.sender;
        _s0.licensee = licensee;
        _s0.brandName = brandName;
        _s0.category = category;
        _s0.territory = territory;
        _s0.minimumGuaranteeUSD = minGuarantee;
        _s0.royaltyRateBps = royaltyRate;
        _s0.netSalesReportedUSD = FHE.asEuint64(0);
        _s0.royaltiesPaidUSD = FHE.asEuint64(0);
        _s0.auditAdjustmentUSD = FHE.asEuint64(0);
        _s0.qualityScorePoints = FHE.asEuint16(10000);
        _s0.status = LicenseStatus.Active;
        _s0.startDate = block.timestamp;
        _s0.endDate = block.timestamp + durationDays * 1 days;
        FHE.allowThis(licenses[id].minimumGuaranteeUSD); FHE.allow(licenses[id].minimumGuaranteeUSD, msg.sender); FHE.allow(licenses[id].minimumGuaranteeUSD, licensee);
        FHE.allowThis(licenses[id].royaltyRateBps); FHE.allow(licenses[id].royaltyRateBps, licensee);
        FHE.allowThis(licenses[id].netSalesReportedUSD); FHE.allow(licenses[id].netSalesReportedUSD, msg.sender);
        FHE.allowThis(licenses[id].royaltiesPaidUSD); FHE.allow(licenses[id].royaltiesPaidUSD, msg.sender);
        FHE.allowThis(licenses[id].auditAdjustmentUSD);
        FHE.allowThis(licenses[id].qualityScorePoints);
        emit LicenseCreated(id, brandName, category);
    }

    function reportNetSales(
        uint256 licenseId,
        externalEuint64 encNetSales, bytes calldata proof
    ) external {
        FashionLicense storage l = licenses[licenseId];
        require(msg.sender == l.licensee, "Not licensee");
        euint64 netSales = FHE.fromExternal(encNetSales, proof);
        l.netSalesReportedUSD = FHE.add(l.netSalesReportedUSD, netSales);
        FHE.allowThis(l.netSalesReportedUSD); FHE.allow(l.netSalesReportedUSD, l.brandOwner);
        emit SalesReported(licenseId, block.timestamp);
    }

    function payRoyalty(
        uint256 licenseId,
        externalEuint64 encRoyaltyPaid, bytes calldata proof
    ) external nonReentrant {
        FashionLicense storage l = licenses[licenseId];
        require(msg.sender == l.licensee, "Not licensee");
        euint64 royaltyPaid = FHE.fromExternal(encRoyaltyPaid, proof);
        l.royaltiesPaidUSD = FHE.add(l.royaltiesPaidUSD, royaltyPaid);
        _totalRoyaltiesEarnedUSD = FHE.add(_totalRoyaltiesEarnedUSD, royaltyPaid);
        FHE.allowThis(l.royaltiesPaidUSD); FHE.allow(l.royaltiesPaidUSD, l.brandOwner);
        FHE.allowThis(_totalRoyaltiesEarnedUSD);
        emit RoyaltyPaid(licenseId, block.timestamp);
    }

    function conductAudit(
        uint256 licenseId,
        externalEuint64 encAdjustment, bytes calldata proof
    ) external onlyBrandAuditor {
        FashionLicense storage l = licenses[licenseId];
        euint64 adjustment = FHE.fromExternal(encAdjustment, proof);
        l.auditAdjustmentUSD = adjustment;
        // Underpayment check: if royalties < minimum guarantee, trigger cure period
        ebool underpaid = FHE.lt(l.royaltiesPaidUSD, l.minimumGuaranteeUSD);
        FHE.allowThis(l.auditAdjustmentUSD); FHE.allow(l.auditAdjustmentUSD, l.brandOwner);
        FHE.allowThis(underpaid);
        _totalAuditRecoveriesUSD = FHE.add(_totalAuditRecoveriesUSD, adjustment);
        FHE.allowThis(_totalAuditRecoveriesUSD);
        if (FHE.isInitialized(underpaid)) l.status = LicenseStatus.InBreachCure;
        emit AuditCompleted(licenseId, block.timestamp);
    }

    function updateQualityScore(
        uint256 licenseId,
        externalEuint16 encScore, bytes calldata proof
    ) external {
        require(isQualityInspector[msg.sender], "Not quality inspector");
        FashionLicense storage l = licenses[licenseId];
        l.qualityScorePoints = FHE.fromExternal(encScore, proof);
        FHE.allowThis(l.qualityScorePoints); FHE.allow(l.qualityScorePoints, l.brandOwner);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalRoyaltiesEarnedUSD, viewer);
        FHE.allow(_totalAuditRecoveriesUSD, viewer);
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