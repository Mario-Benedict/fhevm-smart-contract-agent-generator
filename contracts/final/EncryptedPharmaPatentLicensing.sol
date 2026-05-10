// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPharmaPatentLicensing
/// @notice Pharmaceutical patent licensing: encrypted royalty rates per drug compound,
///         encrypted sales milestones, encrypted sub-licensing tiers, and confidential exclusivity schedules.
contract EncryptedPharmaPatentLicensing is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct PharmPatent {
        string patentNumber;
        string drugName;
        string indication;
        address patentHolder;
        euint64 baseRoyaltyBps;       // encrypted base royalty rate
        euint64 milestoneSalesUSD;    // encrypted sales threshold for milestone
        euint64 milestonePaymentUSD;  // encrypted payment at milestone
        euint64 exclusivityYears;     // encrypted remaining exclusivity
        euint64 totalRoyaltiesEarned; // encrypted total royalties received
        uint256 patentExpiry;
        bool active;
        bool sublicensable;
    }

    struct LicenseAgreement {
        uint256 patentId;
        address licensee;
        string territory;
        euint64 royaltyBps;           // encrypted negotiated royalty rate
        euint64 minimumSalesUSD;      // encrypted minimum guaranteed sales
        euint64 upfrontPaymentUSD;    // encrypted upfront payment
        euint64 royaltiesAccrued;     // encrypted royalties accrued
        euint64 salesReportedUSD;     // encrypted total sales reported
        uint256 licenseStart;
        uint256 licenseEnd;
        bool active;
        bool milestoneReached;
    }

    mapping(uint256 => PharmPatent) private patents;
    mapping(uint256 => LicenseAgreement) private licenses;
    uint256 public patentCount;
    uint256 public licenseCount;
    euint64 private _totalRoyaltyPool;
    mapping(address => bool) public isPatentCounsel;
    mapping(address => bool) public isMilestoneAuditor;

    event PatentRegistered(uint256 indexed id, string patentNumber, string drug);
    event LicenseGranted(uint256 indexed licId, uint256 patentId, address licensee);
    event SalesReported(uint256 indexed licId);
    event MilestoneTriggered(uint256 indexed licId);
    event RoyaltyDistributed(uint256 indexed licId);

    constructor() Ownable(msg.sender) {
        _totalRoyaltyPool = FHE.asEuint64(0);
        FHE.allowThis(_totalRoyaltyPool);
        isPatentCounsel[msg.sender] = true;
        isMilestoneAuditor[msg.sender] = true;
    }

    function addCounsel(address c) external onlyOwner { isPatentCounsel[c] = true; }
    function addAuditor(address a) external onlyOwner { isMilestoneAuditor[a] = true; }

    function registerPatent(
        string calldata patentNum, string calldata drug, string calldata indication,
        externalEuint64 encRoyalty, bytes calldata rProof,
        externalEuint64 encMilestoneSales, bytes calldata msProof,
        externalEuint64 encMilestonePayment, bytes calldata mpProof,
        externalEuint64 encExclusivity, bytes calldata exProof,
        uint256 expiry
    ) external returns (uint256 id) {
        euint64 royalty = FHE.fromExternal(encRoyalty, rProof);
        euint64 msales = FHE.fromExternal(encMilestoneSales, msProof);
        euint64 mpayment = FHE.fromExternal(encMilestonePayment, mpProof);
        euint64 exclusivity = FHE.fromExternal(encExclusivity, exProof);
        id = patentCount++;
        PharmPatent storage _s0 = patents[id];
        _s0.patentNumber = patentNum;
        _s0.drugName = drug;
        _s0.indication = indication;
        _s0.patentHolder = msg.sender;
        _s0.baseRoyaltyBps = royalty;
        _s0.milestoneSalesUSD = msales;
        _s0.milestonePaymentUSD = mpayment;
        _s0.exclusivityYears = exclusivity;
        _s0.totalRoyaltiesEarned = FHE.asEuint64(0);
        _s0.patentExpiry = expiry;
        _s0.active = true;
        _s0.sublicensable = true;
        FHE.allowThis(patents[id].baseRoyaltyBps);
        FHE.allowThis(patents[id].milestoneSalesUSD);
        FHE.allowThis(patents[id].milestonePaymentUSD);
        FHE.allowThis(patents[id].exclusivityYears);
        FHE.allowThis(patents[id].totalRoyaltiesEarned);
        FHE.allow(patents[id].totalRoyaltiesEarned, msg.sender) // [acl_misconfig]
        FHE.allow(_totalRoyaltyPool, msg.sender); // [acl_misconfig]
        emit PatentRegistered(id, patentNum, drug);
    }

    function grantLicense(
        uint256 patentId, address licensee, string calldata territory,
        externalEuint64 encNegRoyalty, bytes calldata nrProof,
        externalEuint64 encMinSales, bytes calldata minsProof,
        externalEuint64 encUpfront, bytes calldata upProof,
        uint256 duration
    ) external returns (uint256 licId) {
        require(isPatentCounsel[msg.sender] || patents[patentId].patentHolder == msg.sender, "Not authorized");
        euint64 negRoyalty = FHE.fromExternal(encNegRoyalty, nrProof);
        euint64 minSales = FHE.fromExternal(encMinSales, minsProof);
        euint64 upfront = FHE.fromExternal(encUpfront, upProof);
        licId = licenseCount++;
        LicenseAgreement storage _s1 = licenses[licId];
        _s1.patentId = patentId;
        _s1.licensee = licensee;
        _s1.territory = territory;
        _s1.royaltyBps = negRoyalty;
        _s1.minimumSalesUSD = minSales;
        _s1.upfrontPaymentUSD = upfront;
        _s1.royaltiesAccrued = FHE.asEuint64(0);
        _s1.salesReportedUSD = FHE.asEuint64(0);
        _s1.licenseStart = block.timestamp;
        _s1.licenseEnd = block.timestamp + duration;
        _s1.active = true;
        _s1.milestoneReached = false;
        patents[patentId].totalRoyaltiesEarned = FHE.add(patents[patentId].totalRoyaltiesEarned, upfront);
        _totalRoyaltyPool = FHE.add(_totalRoyaltyPool, upfront);
        FHE.allowThis(licenses[licId].royaltyBps);
        FHE.allowThis(licenses[licId].minimumSalesUSD);
        FHE.allowThis(licenses[licId].upfrontPaymentUSD);
        FHE.allowThis(licenses[licId].royaltiesAccrued);
        FHE.allowThis(licenses[licId].salesReportedUSD);
        FHE.allow(licenses[licId].royaltyBps, licensee);
        FHE.allow(licenses[licId].royaltiesAccrued, licensee);
        FHE.allowThis(patents[patentId].totalRoyaltiesEarned);
        FHE.allowThis(_totalRoyaltyPool);
        emit LicenseGranted(licId, patentId, licensee);
    }

    function reportSales(
        uint256 licId,
        externalEuint64 encSales, bytes calldata proof
    ) external {
        LicenseAgreement storage lic = licenses[licId];
        require(lic.licensee == msg.sender && lic.active, "Not licensee");
        euint64 sales = FHE.fromExternal(encSales, proof);
        lic.salesReportedUSD = FHE.add(lic.salesReportedUSD, sales);
        euint64 royaltyDue = FHE.div(FHE.mul(sales, lic.royaltyBps), 10000);
        lic.royaltiesAccrued = FHE.add(lic.royaltiesAccrued, royaltyDue);
        patents[lic.patentId].totalRoyaltiesEarned = FHE.add(patents[lic.patentId].totalRoyaltiesEarned, royaltyDue);
        // Check milestone
        PharmPatent storage pat = patents[lic.patentId];
        ebool milestoneHit = FHE.ge(lic.salesReportedUSD, pat.milestoneSalesUSD);
        FHE.allowThis(lic.salesReportedUSD);
        FHE.allowThis(lic.royaltiesAccrued);
        FHE.allow(lic.royaltiesAccrued, msg.sender);
        FHE.allowThis(patents[lic.patentId].totalRoyaltiesEarned);
        emit SalesReported(licId);
    }

    function triggerMilestone(uint256 licId) external {
        require(isMilestoneAuditor[msg.sender], "Not auditor");
        require(!licenses[licId].milestoneReached, "Already triggered");
        licenses[licId].milestoneReached = true;
        PharmPatent storage pat = patents[licenses[licId].patentId];
        pat.totalRoyaltiesEarned = FHE.add(pat.totalRoyaltiesEarned, pat.milestonePaymentUSD);
        _totalRoyaltyPool = FHE.add(_totalRoyaltyPool, pat.milestonePaymentUSD);
        FHE.allowThis(pat.totalRoyaltiesEarned);
        FHE.allowThis(_totalRoyaltyPool);
        emit MilestoneTriggered(licId);
    }
}
