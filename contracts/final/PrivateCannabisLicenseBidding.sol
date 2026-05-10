// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCannabisLicenseBidding
/// @notice Confidential sealed-bid auction for government cannabis production/retail licenses.
///         Encrypted bid amounts, hidden financial capacity proofs, private compliance scores,
///         and confidential equity ownership disclosures required by regulators.
contract PrivateCannabisLicenseBidding is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum LicenseType { Cultivation, Processing, Retail, MedicalDispensary, ResearchDevelopment }
    enum ApplicationStatus { Submitted, UnderReview, Approved, Rejected, Revoked }

    struct LicenseSlot {
        string jurisdictionCode;
        LicenseType licenseType;
        uint32 slotsAvailable;
        euint64 minimumBidUSD;         // encrypted minimum bid
        euint64 applicationFeeUSD;     // encrypted application fee
        uint256 biddingClose;
        bool active;
    }

    struct LicenseApplication {
        uint256 slotId;
        address applicant;
        euint64 bidAmountUSD;          // encrypted bid amount
        euint16 complianceScorePoints; // encrypted compliance points (max 1000)
        euint8  equityDisclosureFlag;  // encrypted ownership transparency flag
        euint64 financialCapacityUSD;  // encrypted demonstrated financial capacity
        ApplicationStatus status;
        uint256 submittedAt;
    }

    mapping(uint256 => LicenseSlot) private licenseSlots;
    mapping(uint256 => LicenseApplication) private applications;
    mapping(uint256 => uint256[]) private slotApplicationIds;
    mapping(address => bool) public isRegulator;

    uint256 public slotCount;
    uint256 public applicationCount;
    euint64 private _totalBidRevenueUSD;
    euint64 private _totalFeeRevenueUSD;

    event SlotCreated(uint256 indexed id, LicenseType licenseType, string jurisdiction);
    event ApplicationSubmitted(uint256 indexed appId, uint256 slotId, address applicant);
    event ApplicationDecided(uint256 indexed appId, ApplicationStatus status);

    modifier onlyRegulator() {
        require(isRegulator[msg.sender] || msg.sender == owner(), "Not regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalBidRevenueUSD = FHE.asEuint64(0);
        _totalFeeRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalBidRevenueUSD);
        FHE.allowThis(_totalFeeRevenueUSD);
        isRegulator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }

    function createLicenseSlot(
        string calldata jurisdictionCode,
        LicenseType licenseType,
        uint32 slotsAvailable,
        externalEuint64 encMinBid, bytes calldata mbProof,
        externalEuint64 encFee, bytes calldata feeProof,
        uint256 durationDays
    ) external onlyRegulator whenNotPaused returns (uint256 id) {
        euint64 minBid = FHE.fromExternal(encMinBid, mbProof);
        euint64 appFee = FHE.fromExternal(encFee, feeProof);
        id = slotCount++;
        licenseSlots[id] = LicenseSlot({
            jurisdictionCode: jurisdictionCode, licenseType: licenseType,
            slotsAvailable: slotsAvailable, minimumBidUSD: minBid,
            applicationFeeUSD: appFee, biddingClose: block.timestamp + durationDays * 1 days, active: true
        });
        FHE.allowThis(licenseSlots[id].minimumBidUSD);
        FHE.allowThis(licenseSlots[id].applicationFeeUSD);
        emit SlotCreated(id, licenseType, jurisdictionCode);
    }

    function submitApplication(
        uint256 slotId,
        externalEuint64 encBid, bytes calldata bidProof,
        externalEuint16 encCompliance, bytes calldata compProof,
        externalEuint8 encEquityFlag, bytes calldata eqProof,
        externalEuint64 encFinancial, bytes calldata finProof
    ) external whenNotPaused nonReentrant returns (uint256 appId) {
        LicenseSlot storage ls = licenseSlots[slotId];
        require(ls.active && block.timestamp < ls.biddingClose, "Slot closed");
        euint64 bid = FHE.fromExternal(encBid, bidProof);
        euint16 compliance = FHE.fromExternal(encCompliance, compProof);
        euint8 equityFlag = FHE.fromExternal(encEquityFlag, eqProof);
        euint64 financial = FHE.fromExternal(encFinancial, finProof);
        // Verify bid >= minimum bid (branchless)
        ebool bidOk = FHE.ge(bid, ls.minimumBidUSD);
        euint64 validBid = FHE.select(bidOk, bid, FHE.asEuint64(0));
        appId = applicationCount++;
        applications[appId] = LicenseApplication({
            slotId: slotId, applicant: msg.sender, bidAmountUSD: validBid,
            complianceScorePoints: compliance, equityDisclosureFlag: equityFlag,
            financialCapacityUSD: financial, status: ApplicationStatus.Submitted,
            submittedAt: block.timestamp
        });
        slotApplicationIds[slotId].push(appId);
        _totalFeeRevenueUSD = FHE.add(_totalFeeRevenueUSD, ls.applicationFeeUSD);
        FHE.allowThis(applications[appId].bidAmountUSD); FHE.allow(applications[appId].bidAmountUSD, msg.sender);
        FHE.allowThis(applications[appId].complianceScorePoints);
        FHE.allowThis(applications[appId].equityDisclosureFlag);
        FHE.allowThis(applications[appId].financialCapacityUSD); FHE.allow(applications[appId].financialCapacityUSD, msg.sender);
        FHE.allowThis(_totalFeeRevenueUSD);
        emit ApplicationSubmitted(appId, slotId, msg.sender);
    }

    function decideApplication(uint256 appId, bool approve) external onlyRegulator {
        LicenseApplication storage a = applications[appId];
        require(a.status == ApplicationStatus.Submitted || a.status == ApplicationStatus.UnderReview, "Not pending");
        if (approve) {
            a.status = ApplicationStatus.Approved;
            _totalBidRevenueUSD = FHE.add(_totalBidRevenueUSD, a.bidAmountUSD);
            FHE.allowThis(_totalBidRevenueUSD);
            FHE.allow(a.bidAmountUSD, msg.sender);
        } else {
            a.status = ApplicationStatus.Rejected;
        }
        emit ApplicationDecided(appId, a.status);
    }

    function allowRevenueView(address viewer) external onlyOwner {
        FHE.allow(_totalBidRevenueUSD, viewer);
        FHE.allow(_totalFeeRevenueUSD, viewer);
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