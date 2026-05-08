// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateTradeSecretLicensing
/// @notice Trade secret IP licensing: encrypted royalty rates per territory, encrypted usage metrics,
///         encrypted enforcement penalty tiers, and confidential audit log of licensee revenue.
contract PrivateTradeSecretLicensing is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LicenseAgreement {
        address licensor;
        address licensee;
        string assetId;          // e.g. patent number / trade secret reference
        euint64 royaltyRateBps;  // encrypted royalty rate (basis points of revenue)
        euint64 minimumGuarantee;// encrypted minimum annual guarantee
        euint64 revenueReported; // encrypted total licensee revenue reported
        euint64 royaltiesOwed;   // encrypted total royalties owed
        euint64 royaltiesPaid;   // encrypted royalties paid to date
        uint256 startDate;
        uint256 endDate;
        bool active;
        bool disputed;
    }

    struct RevenueReport {
        uint256 licenseId;
        euint64 quarterlyRevenue; // encrypted quarter revenue
        euint64 royaltyDue;       // encrypted royalty this quarter
        uint256 period;           // encoded YYYYQ (e.g. 20241 = Q1 2024)
        bool verified;
    }

    struct EnforcementAction {
        uint256 licenseId;
        euint64 penaltyAmount;   // encrypted penalty
        euint8 violationSeverity; // encrypted severity 1-5
        string violationType;
        bool resolved;
    }

    mapping(uint256 => LicenseAgreement) private licenses;
    mapping(uint256 => RevenueReport) private reports;
    mapping(uint256 => EnforcementAction) private enforcements;
    mapping(address => uint256[]) private licensorLicenses;
    mapping(address => uint256[]) private licenseeLicenses;
    uint256 public licenseCount;
    uint256 public reportCount;
    uint256 public enforcementCount;
    mapping(address => bool) public isLicensingAgent;

    event LicenseGranted(uint256 indexed id, address licensor, address licensee, string assetId);
    event RevenueReported(uint256 indexed reportId, uint256 indexed licenseId);
    event RoyaltyPaid(uint256 indexed licenseId);
    event EnforcementRaised(uint256 indexed enfId, uint256 licenseId);
    event DisputeRaised(uint256 indexed licenseId);

    constructor() Ownable(msg.sender) {
        isLicensingAgent[msg.sender] = true;
    }

    function addAgent(address a) external onlyOwner { isLicensingAgent[a] = true; }

    function grantLicense(
        address licensee, string calldata assetId,
        externalEuint64 encRate, bytes calldata rProof,
        externalEuint64 encMinGuarantee, bytes calldata mProof,
        uint256 startDate, uint256 endDate
    ) external returns (uint256 id) {
        euint64 rate = FHE.fromExternal(encRate, rProof);
        euint64 minG = FHE.fromExternal(encMinGuarantee, mProof);
        id = licenseCount++;
        licenses[id] = LicenseAgreement({
            licensor: msg.sender, licensee: licensee, assetId: assetId,
            royaltyRateBps: rate, minimumGuarantee: minG,
            revenueReported: FHE.asEuint64(0),
            royaltiesOwed: FHE.asEuint64(0),
            royaltiesPaid: FHE.asEuint64(0),
            startDate: startDate, endDate: endDate, active: true, disputed: false
        });
        licensorLicenses[msg.sender].push(id);
        licenseeLicenses[licensee].push(id);
        FHE.allowThis(licenses[id].royaltyRateBps);
        FHE.allowThis(licenses[id].minimumGuarantee);
        FHE.allowThis(licenses[id].revenueReported);
        FHE.allowThis(licenses[id].royaltiesOwed);
        FHE.allowThis(licenses[id].royaltiesPaid);
        FHE.allow(licenses[id].royaltyRateBps, licensee);
        FHE.allow(licenses[id].minimumGuarantee, licensee);
        emit LicenseGranted(id, msg.sender, licensee, assetId);
    }

    function reportRevenue(
        uint256 licenseId,
        externalEuint64 encRevenue, bytes calldata proof,
        uint256 period
    ) external returns (uint256 reportId) {
        LicenseAgreement storage lic = licenses[licenseId];
        require(lic.licensee == msg.sender && lic.active, "Not licensee or inactive");
        euint64 revenue = FHE.fromExternal(encRevenue, proof);
        euint64 royalty = FHE.div(FHE.mul(revenue, lic.royaltyRateBps), 10000);
        // Apply minimum guarantee: royalty = max(royalty, minimumGuarantee/4)
        euint64 quarterlyMin = FHE.div(lic.minimumGuarantee, 4);
        ebool aboveMin = FHE.ge(royalty, quarterlyMin);
        euint64 finalRoyalty = FHE.select(aboveMin, royalty, quarterlyMin);
        reportId = reportCount++;
        reports[reportId] = RevenueReport({
            licenseId: licenseId, quarterlyRevenue: revenue,
            royaltyDue: finalRoyalty, period: period, verified: false
        });
        lic.revenueReported = FHE.add(lic.revenueReported, revenue);
        lic.royaltiesOwed = FHE.add(lic.royaltiesOwed, finalRoyalty);
        FHE.allowThis(reports[reportId].quarterlyRevenue);
        FHE.allowThis(reports[reportId].royaltyDue);
        FHE.allow(reports[reportId].royaltyDue, lic.licensor);
        FHE.allowThis(lic.revenueReported);
        FHE.allowThis(lic.royaltiesOwed);
        FHE.allow(lic.royaltiesOwed, lic.licensor);
        emit RevenueReported(reportId, licenseId);
    }

    function payRoyalty(uint256 licenseId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        LicenseAgreement storage lic = licenses[licenseId];
        require(lic.licensee == msg.sender, "Not licensee");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool withinOwed = FHE.le(amount, lic.royaltiesOwed);
        euint64 actual = FHE.select(withinOwed, amount, lic.royaltiesOwed);
        lic.royaltiesPaid = FHE.add(lic.royaltiesPaid, actual);
        lic.royaltiesOwed = FHE.sub(lic.royaltiesOwed, actual);
        FHE.allowThis(lic.royaltiesPaid);
        FHE.allow(lic.royaltiesPaid, lic.licensor);
        FHE.allowThis(lic.royaltiesOwed);
        emit RoyaltyPaid(licenseId);
    }

    function raiseEnforcement(
        uint256 licenseId,
        externalEuint64 encPenalty, bytes calldata pProof,
        externalEuint8 encSeverity, bytes calldata sProof,
        string calldata violationType
    ) external returns (uint256 enfId) {
        require(licenses[licenseId].licensor == msg.sender || isLicensingAgent[msg.sender], "Not authorized");
        euint64 penalty = FHE.fromExternal(encPenalty, pProof);
        euint8 severity = FHE.fromExternal(encSeverity, sProof);
        enfId = enforcementCount++;
        enforcements[enfId] = EnforcementAction({
            licenseId: licenseId, penaltyAmount: penalty,
            violationSeverity: severity, violationType: violationType, resolved: false
        });
        FHE.allowThis(enforcements[enfId].penaltyAmount);
        FHE.allowThis(enforcements[enfId].violationSeverity);
        emit EnforcementRaised(enfId, licenseId);
    }

    function raiseDispute(uint256 licenseId) external {
        LicenseAgreement storage lic = licenses[licenseId];
        require(msg.sender == lic.licensor || msg.sender == lic.licensee, "Not party");
        lic.disputed = true;
        emit DisputeRaised(licenseId);
    }
}
