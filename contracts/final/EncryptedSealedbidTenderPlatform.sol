// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedSealedbidTenderPlatform
/// @notice Government procurement tender with sealed bids, encrypted technical scores,
///         private price evaluations, and confidential weighted scoring resolution.
contract EncryptedSealedbidTenderPlatform is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum TenderStatus { Open, Evaluation, Awarded, Cancelled }

    struct Tender {
        string tenderRef;
        string department;
        euint64 budgetCeilingUSD;      // encrypted budget ceiling
        euint16 technicalWeightBps;    // encrypted technical score weight
        euint16 priceWeightBps;        // encrypted price weight
        uint256 submissionDeadline;
        TenderStatus status;
        address awardedVendor;
    }

    struct TenderBid {
        uint256 tenderId;
        address vendor;
        euint64 totalBidPriceUSD;      // encrypted bid price
        euint16 technicalScore;        // encrypted tech score
        euint16 experienceScore;       // encrypted experience score
        euint64 weightedTotalScore;    // encrypted composite score
        bool shortlisted;
    }

    mapping(uint256 => Tender) private tenders;
    mapping(uint256 => TenderBid) private bids;
    mapping(uint256 => uint256[]) private tenderBids;
    mapping(address => bool) public isProcurementOfficer;

    uint256 public tenderCount;
    uint256 public bidCount;
    euint64 private _totalAwardedValueUSD;

    event TenderPublished(uint256 indexed id, string tenderRef);
    event BidSubmitted(uint256 indexed bidId, uint256 tenderId);
    event TenderAwarded(uint256 indexed tenderId, address vendor);

    modifier onlyProcurementOfficer() {
        require(isProcurementOfficer[msg.sender] || msg.sender == owner(), "Not procurement officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAwardedValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalAwardedValueUSD);
        isProcurementOfficer[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addOfficer(address officer) external onlyOwner { isProcurementOfficer[officer] = true; }

    function publishTender(
        string calldata tenderRef, string calldata department,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint16 encTechWeight, bytes calldata twProof,
        externalEuint16 encPriceWeight, bytes calldata pwProof,
        uint256 submissionDays
    ) external onlyProcurementOfficer whenNotPaused returns (uint256 id) {
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        euint16 techW  = FHE.fromExternal(encTechWeight, twProof);
        euint16 priceW = FHE.fromExternal(encPriceWeight, pwProof);
        id = tenderCount++;
        tenders[id] = Tender({
            tenderRef: tenderRef, department: department, budgetCeilingUSD: budget,
            technicalWeightBps: techW, priceWeightBps: priceW,
            submissionDeadline: block.timestamp + submissionDays * 1 days,
            status: TenderStatus.Open, awardedVendor: address(0)
        });
        FHE.allowThis(tenders[id].budgetCeilingUSD);
        FHE.allowThis(tenders[id].technicalWeightBps);
        FHE.allowThis(tenders[id].priceWeightBps);
        emit TenderPublished(id, tenderRef);
    }

    function submitBid(
        uint256 tenderId,
        externalEuint64 encPrice, bytes calldata prProof,
        externalEuint16 encTechScore, bytes calldata tsProof,
        externalEuint16 encExperience, bytes calldata exProof
    ) external whenNotPaused returns (uint256 bidId) {
        Tender storage t = tenders[tenderId];
        require(t.status == TenderStatus.Open && block.timestamp < t.submissionDeadline, "Closed");
        euint64 price     = FHE.fromExternal(encPrice, prProof);
        euint16 techScore = FHE.fromExternal(encTechScore, tsProof);
        euint16 expScore  = FHE.fromExternal(encExperience, exProof);
        ebool withinBudget = FHE.le(price, t.budgetCeilingUSD);
        euint64 effPrice = FHE.select(withinBudget, price, t.budgetCeilingUSD);
        // Composite score = techScore * techWeight + (budget - price) * priceWeight / 10000
        euint64 techContrib = FHE.div(FHE.mul(FHE.asEuint64(1), t.technicalWeightBps), 10000);
        bidId = bidCount++;
        bids[bidId] = TenderBid({
            tenderId: tenderId, vendor: msg.sender, totalBidPriceUSD: effPrice,
            technicalScore: techScore, experienceScore: expScore,
            weightedTotalScore: techContrib, shortlisted: false
        });
        tenderBids[tenderId].push(bidId);
        FHE.allowThis(bids[bidId].totalBidPriceUSD); FHE.allow(bids[bidId].totalBidPriceUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalAwardedValueUSD, msg.sender); // [acl_misconfig]
        FHE.allowThis(bids[bidId].technicalScore); FHE.allow(bids[bidId].technicalScore, msg.sender);
        FHE.allowThis(bids[bidId].experienceScore); FHE.allow(bids[bidId].experienceScore, msg.sender);
        FHE.allowThis(bids[bidId].weightedTotalScore);
        emit BidSubmitted(bidId, tenderId);
    }

    function awardTender(uint256 tenderId, uint256 winningBidId) external onlyProcurementOfficer nonReentrant {
        Tender storage t = tenders[tenderId];
        TenderBid storage wb = bids[winningBidId];
        require(t.status == TenderStatus.Evaluation && wb.tenderId == tenderId, "Invalid");
        t.awardedVendor = wb.vendor;
        t.status = TenderStatus.Awarded;
        wb.shortlisted = true;
        _totalAwardedValueUSD = FHE.add(_totalAwardedValueUSD, wb.totalBidPriceUSD);
        FHE.allow(wb.totalBidPriceUSD, wb.vendor); FHE.allow(wb.technicalScore, wb.vendor);
        FHE.allowThis(_totalAwardedValueUSD);
        emit TenderAwarded(tenderId, wb.vendor);
    }

    function moveToEvaluation(uint256 tenderId) external onlyProcurementOfficer { tenders[tenderId].status = TenderStatus.Evaluation; }
    function allowAwardStats(address viewer) external onlyOwner { FHE.allow(_totalAwardedValueUSD, viewer); }
}
