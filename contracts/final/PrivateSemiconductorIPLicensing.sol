// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSemiconductorIPLicensing
/// @notice Semiconductor IP core licensing: encrypted royalty rates, design-win fees,
///         and volume milestone payments negotiated confidentially between IP house and chip maker.
contract PrivateSemiconductorIPLicensing is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum IPCoreType { CPU, GPU, DSP, MemoryController, PHY, SerDes, Interconnect }
    enum LicenseType { DesignOnly, DesignAndManufacturing, Perpetual, Subscription }
    enum LicenseStatus { Active, Expired, Terminated, Breached }

    struct IPCoreLicense {
        address ipHouse;
        address chipMaker;
        IPCoreType coreType;
        LicenseType licenseType;
        string coreName;
        string processNode;             // e.g. "3nm", "5nm"
        euint64 upfrontFeeUSD;         // encrypted upfront licensing fee
        euint32 royaltyRateBps;        // encrypted royalty rate per unit
        euint64 minimumRoyaltyUSD;     // encrypted annual minimum
        euint64 totalRoyaltiesPaidUSD; // encrypted cumulative royalties
        euint64 volumeMilestone;       // encrypted unit milestone for bonus
        uint256 expiryDate;
        LicenseStatus status;
    }

    struct RoyaltyReport {
        uint256 licenseId;
        euint64 unitsShipped;          // encrypted units in period
        euint64 royaltyDueUSD;         // encrypted computed royalty
        uint256 period;                // timestamp of reporting period
        bool paid;
    }

    mapping(uint256 => IPCoreLicense) private licenses;
    mapping(uint256 => RoyaltyReport[]) private reports;
    mapping(address => bool) public isIPHouse;
    mapping(address => bool) public isChipMaker;
    mapping(address => bool) public isAuditor;

    uint256 public licenseCount;
    euint64 private _totalRoyaltiesCollected;
    euint64 private _totalIPMarketValue;

    event LicenseGranted(uint256 indexed id, address ipHouse, address chipMaker, IPCoreType coreType);
    event RoyaltyReported(uint256 indexed licenseId, uint256 reportIndex);
    event RoyaltyPaid(uint256 indexed licenseId, uint256 reportIndex);
    event LicenseTerminated(uint256 indexed id, string reason);

    modifier onlyAuditor() {
        require(isAuditor[msg.sender] || msg.sender == owner(), "Not auditor");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRoyaltiesCollected = FHE.asEuint64(0);
        _totalIPMarketValue = FHE.asEuint64(0);
        FHE.allowThis(_totalRoyaltiesCollected);
        FHE.allowThis(_totalIPMarketValue);
        isAuditor[msg.sender] = true;
    }

    function registerIPHouse(address h) external onlyOwner { isIPHouse[h] = true; }
    function registerChipMaker(address c) external onlyOwner { isChipMaker[c] = true; }
    function addAuditor(address a) external onlyOwner { isAuditor[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function grantLicense(
        address chipMaker,
        IPCoreType coreType,
        LicenseType licenseType,
        string calldata coreName,
        string calldata processNode,
        externalEuint64 encUpfront, bytes calldata uProof,
        externalEuint32 encRoyaltyRate, bytes calldata rProof,
        externalEuint64 encMinRoyalty, bytes calldata mProof,
        externalEuint64 encMilestone, bytes calldata msProof,
        uint256 licenseYears
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        require(isIPHouse[msg.sender], "Not IP house");
        require(isChipMaker[chipMaker], "Not chip maker");
        euint64 upfront = FHE.fromExternal(encUpfront, uProof);
        euint32 royaltyRate = FHE.fromExternal(encRoyaltyRate, rProof);
        euint64 minRoyalty = FHE.fromExternal(encMinRoyalty, mProof);
        euint64 milestone = FHE.fromExternal(encMilestone, msProof);
        id = licenseCount++;
        IPCoreLicense storage _s0 = licenses[id];
        _s0.ipHouse = msg.sender;
        _s0.chipMaker = chipMaker;
        _s0.coreType = coreType;
        _s0.licenseType = licenseType;
        _s0.coreName = coreName;
        _s0.processNode = processNode;
        _s0.upfrontFeeUSD = upfront;
        _s0.royaltyRateBps = royaltyRate;
        _s0.minimumRoyaltyUSD = minRoyalty;
        _s0.totalRoyaltiesPaidUSD = FHE.asEuint64(0);
        _s0.volumeMilestone = milestone;
        _s0.expiryDate = block.timestamp + licenseYears * 365 days;
        _s0.status = LicenseStatus.Active;
        _totalIPMarketValue = FHE.add(_totalIPMarketValue, upfront);
        FHE.allowThis(licenses[id].upfrontFeeUSD);
        FHE.allow(licenses[id].upfrontFeeUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalRoyaltiesCollected, msg.sender); // [acl_misconfig]
        FHE.allow(_totalIPMarketValue, msg.sender); // [acl_misconfig]
        FHE.allow(licenses[id].upfrontFeeUSD, chipMaker);
        FHE.allowThis(licenses[id].royaltyRateBps);
        FHE.allow(licenses[id].royaltyRateBps, msg.sender);
        FHE.allow(licenses[id].royaltyRateBps, chipMaker);
        FHE.allowThis(licenses[id].minimumRoyaltyUSD);
        FHE.allow(licenses[id].minimumRoyaltyUSD, chipMaker);
        FHE.allowThis(licenses[id].totalRoyaltiesPaidUSD);
        FHE.allow(licenses[id].totalRoyaltiesPaidUSD, msg.sender);
        FHE.allowThis(licenses[id].volumeMilestone);
        FHE.allow(licenses[id].volumeMilestone, chipMaker);
        FHE.allowThis(_totalIPMarketValue);
        emit LicenseGranted(id, msg.sender, chipMaker, coreType);
    }

    function submitRoyaltyReport(
        uint256 licenseId,
        externalEuint64 encUnits, bytes calldata uProof,
        uint256 period
    ) external nonReentrant {
        IPCoreLicense storage l = licenses[licenseId];
        require(l.chipMaker == msg.sender && l.status == LicenseStatus.Active, "Not licensee or inactive");
        euint64 units = FHE.fromExternal(encUnits, uProof);
        euint64 royalty = FHE.mul(units, FHE.asEuint64(0)); // base royalty computation placeholder
        // Enforce minimum royalty
        ebool aboveMin = FHE.ge(royalty, l.minimumRoyaltyUSD);
        euint64 finalRoyalty = FHE.select(aboveMin, royalty, l.minimumRoyaltyUSD);
        RoyaltyReport memory rep = RoyaltyReport({
            licenseId: licenseId, unitsShipped: units,
            royaltyDueUSD: finalRoyalty, period: period, paid: false
        });
        reports[licenseId].push(rep);
        FHE.allowThis(rep.unitsShipped);
        FHE.allow(rep.unitsShipped, l.ipHouse);
        FHE.allowThis(rep.royaltyDueUSD);
        FHE.allow(rep.royaltyDueUSD, l.ipHouse);
        FHE.allow(rep.royaltyDueUSD, msg.sender);
        emit RoyaltyReported(licenseId, reports[licenseId].length - 1);
    }

    function confirmRoyaltyPayment(uint256 licenseId, uint256 reportIndex) external onlyAuditor nonReentrant {
        IPCoreLicense storage l = licenses[licenseId];
        RoyaltyReport storage rep = reports[licenseId][reportIndex];
        require(!rep.paid, "Already paid");
        rep.paid = true;
        l.totalRoyaltiesPaidUSD = FHE.add(l.totalRoyaltiesPaidUSD, rep.royaltyDueUSD);
        _totalRoyaltiesCollected = FHE.add(_totalRoyaltiesCollected, rep.royaltyDueUSD);
        FHE.allowThis(l.totalRoyaltiesPaidUSD);
        FHE.allow(l.totalRoyaltiesPaidUSD, l.ipHouse);
        FHE.allowThis(_totalRoyaltiesCollected);
        emit RoyaltyPaid(licenseId, reportIndex);
    }

    function terminateLicense(uint256 licenseId, string calldata reason) external onlyAuditor {
        licenses[licenseId].status = LicenseStatus.Terminated;
        emit LicenseTerminated(licenseId, reason);
    }

    function allowLicenseDetails(uint256 licenseId, address viewer) external onlyAuditor {
        IPCoreLicense storage l = licenses[licenseId];
        FHE.allow(l.upfrontFeeUSD, viewer);
        FHE.allow(l.royaltyRateBps, viewer);
        FHE.allow(l.minimumRoyaltyUSD, viewer);
        FHE.allow(l.totalRoyaltiesPaidUSD, viewer);
    }

    function allowIPStats(address viewer) external onlyOwner {
        FHE.allow(_totalRoyaltiesCollected, viewer);
        FHE.allow(_totalIPMarketValue, viewer);
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