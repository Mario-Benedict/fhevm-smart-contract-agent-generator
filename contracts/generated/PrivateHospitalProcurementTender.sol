// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateHospitalProcurementTender
/// @notice Hospitals issue encrypted tenders for medical supplies. Vendors submit sealed bids.
///         Lowest qualified bid wins. Vendor financial health scores remain confidential.
contract PrivateHospitalProcurementTender is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum TenderStatus { Draft, Open, Evaluation, Awarded, Cancelled }
    enum SupplyCategory { Pharmaceuticals, MedicalDevices, PPE, LabReagents, SurgicalImplants }

    struct Tender {
        string hospitalName;
        SupplyCategory category;
        string itemDescription;
        euint64 estimatedBudgetUSD;    // encrypted budget
        euint32 requiredQualityScore;  // encrypted min quality threshold
        uint256 submissionDeadline;
        uint256 awardDate;
        TenderStatus status;
        uint256 winningBidId;
    }

    struct VendorBid {
        uint256 tenderId;
        address vendor;
        euint64 bidPriceUSD;           // encrypted total bid price
        euint32 qualityScore;          // encrypted quality/compliance score
        euint32 deliveryDays;          // encrypted delivery timeline
        euint64 financialStrength;     // encrypted vendor financial rating
        bool disqualified;
    }

    mapping(uint256 => Tender) private tenders;
    mapping(uint256 => VendorBid) private bids;
    mapping(address => bool) public isQualifiedVendor;
    mapping(address => bool) public isEvaluator;

    uint256 public tenderCount;
    uint256 public bidCount;
    euint64 private _totalProcuredUSD;

    event TenderIssued(uint256 indexed id, SupplyCategory category);
    event BidSubmitted(uint256 indexed bidId, uint256 tenderId, address vendor);
    event TenderAwarded(uint256 indexed tenderId, uint256 bidId, address vendor);

    modifier onlyEvaluator() {
        require(isEvaluator[msg.sender] || msg.sender == owner(), "Not evaluator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalProcuredUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalProcuredUSD);
        isEvaluator[msg.sender] = true;
    }

    function addVendor(address v) external onlyOwner { isQualifiedVendor[v] = true; }
    function addEvaluator(address e) external onlyOwner { isEvaluator[e] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function issueTender(
        string calldata hospitalName,
        SupplyCategory category,
        string calldata itemDesc,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint32 encMinQuality, bytes calldata qProof,
        uint256 submissionDays
    ) external onlyOwner whenNotPaused returns (uint256 id) {
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        euint32 minQ = FHE.fromExternal(encMinQuality, qProof);
        id = tenderCount++;
        tenders[id] = Tender({
            hospitalName: hospitalName, category: category, itemDescription: itemDesc,
            estimatedBudgetUSD: budget, requiredQualityScore: minQ,
            submissionDeadline: block.timestamp + submissionDays * 1 days,
            awardDate: 0, status: TenderStatus.Open, winningBidId: type(uint256).max
        });
        FHE.allowThis(tenders[id].estimatedBudgetUSD);
        FHE.allowThis(tenders[id].requiredQualityScore);
        emit TenderIssued(id, category);
    }

    function submitBid(
        uint256 tenderId,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint32 encQuality, bytes calldata qProof,
        externalEuint32 encDelivery, bytes calldata dProof,
        externalEuint64 encFinancial, bytes calldata fProof
    ) external whenNotPaused nonReentrant returns (uint256 bidId) {
        require(isQualifiedVendor[msg.sender], "Not qualified vendor");
        Tender storage t = tenders[tenderId];
        require(t.status == TenderStatus.Open && block.timestamp < t.submissionDeadline, "Not open");
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint32 quality = FHE.fromExternal(encQuality, qProof);
        euint32 delivery = FHE.fromExternal(encDelivery, dProof);
        euint64 financial = FHE.fromExternal(encFinancial, fProof);
        // Check quality meets minimum
        ebool qualityOk = FHE.ge(quality, t.requiredQualityScore);
        euint64 effectivePrice = FHE.select(qualityOk, price, FHE.asEuint64(type(uint64).max));
        bidId = bidCount++;
        bids[bidId] = VendorBid({
            tenderId: tenderId, vendor: msg.sender,
            bidPriceUSD: effectivePrice, qualityScore: quality,
            deliveryDays: delivery, financialStrength: financial,
            disqualified: false
        });
        FHE.allowThis(bids[bidId].bidPriceUSD);
        FHE.allow(bids[bidId].bidPriceUSD, msg.sender);
        FHE.allowThis(bids[bidId].qualityScore);
        FHE.allow(bids[bidId].qualityScore, msg.sender);
        FHE.allowThis(bids[bidId].deliveryDays);
        FHE.allow(bids[bidId].deliveryDays, msg.sender);
        FHE.allowThis(bids[bidId].financialStrength);
        emit BidSubmitted(bidId, tenderId, msg.sender);
    }

    function awardTender(uint256 tenderId, uint256 winningBidId) external onlyEvaluator nonReentrant {
        Tender storage t = tenders[tenderId];
        require(t.status == TenderStatus.Open || t.status == TenderStatus.Evaluation, "Invalid state");
        require(block.timestamp >= t.submissionDeadline, "Bids still open");
        VendorBid storage b = bids[winningBidId];
        require(b.tenderId == tenderId && !b.disqualified, "Invalid bid");
        t.status = TenderStatus.Awarded;
        t.winningBidId = winningBidId;
        t.awardDate = block.timestamp;
        _totalProcuredUSD = FHE.add(_totalProcuredUSD, b.bidPriceUSD);
        FHE.allowThis(_totalProcuredUSD);
        FHE.allow(b.bidPriceUSD, b.vendor);
        emit TenderAwarded(tenderId, winningBidId, b.vendor);
    }

    function disqualifyBid(uint256 bidId) external onlyEvaluator {
        bids[bidId].disqualified = true;
    }

    function allowProcurementStats(address viewer) external onlyOwner {
        FHE.allow(_totalProcuredUSD, viewer);
    }
}
