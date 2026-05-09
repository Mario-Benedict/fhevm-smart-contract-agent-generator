// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateDefenseContractBidding
/// @notice Encrypted defense procurement bidding: hidden bid prices, confidential technical
///         capability scores, private security clearance validation, and encrypted
///         subcontractor diversity metrics.
contract PrivateDefenseContractBidding is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ContractCategory { Aircraft, NavalSystems, LandVehicles, Cyber, ISR, Logistics, Communications }
    enum ClearanceLevel { Public, Confidential, Secret, TopSecret, SCI }
    enum AwardStatus { Open, EvaluationPhase, Awarded, Cancelled }

    struct DefenseRFP {
        string rfpNumber;
        ContractCategory category;
        ClearanceLevel minClearance;
        euint64 estimatedValueUSD;     // encrypted contract value estimate
        euint64 awardedValueUSD;       // encrypted actual award value
        euint16 technicalWeightBps;    // encrypted scoring weight for tech
        euint16 priceWeightBps;        // encrypted scoring weight for price
        address awardedVendor;
        AwardStatus status;
        uint256 proposalDeadline;
    }

    struct VendorBid {
        uint256 rfpId;
        address vendor;
        ClearanceLevel vendorClearance;
        euint64 totalBidPriceUSD;      // encrypted total bid price
        euint16 technicalScoreBps;     // encrypted technical score
        euint16 diversityScoreBps;     // encrypted small business/diversity metric
        euint8  securityPostureScore;  // encrypted cybersecurity rating
        bool accepted;
    }

    mapping(uint256 => DefenseRFP) private rfps;
    mapping(uint256 => VendorBid) private vendorBids;
    mapping(address => bool) public isProcurementOfficer;
    mapping(address => ClearanceLevel) public vendorClearance;

    uint256 public rfpCount;
    uint256 public bidCount;
    euint64 private _totalContractValueAwardedUSD;

    event RFPPublished(uint256 indexed id, string rfpNumber, ContractCategory category);
    event BidSubmitted(uint256 indexed bidId, uint256 rfpId);
    event ContractAwarded(uint256 indexed rfpId, address vendor);

    modifier onlyProcurementOfficer() {
        require(isProcurementOfficer[msg.sender] || msg.sender == owner(), "Not procurement officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalContractValueAwardedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalContractValueAwardedUSD);
        isProcurementOfficer[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addProcurementOfficer(address po) external onlyOwner { isProcurementOfficer[po] = true; }
    function setVendorClearance(address vendor, ClearanceLevel level) external onlyOwner { vendorClearance[vendor] = level; }

    function publishRFP(
        string calldata rfpNumber, ContractCategory category, ClearanceLevel minClearance,
        externalEuint64 encEstValue, bytes calldata evProof,
        externalEuint16 encTechWeight, bytes calldata twProof,
        externalEuint16 encPriceWeight, bytes calldata pwProof,
        uint256 deadlineDays
    ) external onlyProcurementOfficer whenNotPaused returns (uint256 id) {
        euint64 estValue = FHE.fromExternal(encEstValue, evProof);
        euint16 techWeight = FHE.fromExternal(encTechWeight, twProof);
        euint16 priceWeight = FHE.fromExternal(encPriceWeight, pwProof);
        id = rfpCount++;
        rfps[id].rfpNumber = rfpNumber;
        rfps[id].category = category;
        rfps[id].minClearance = minClearance;
        rfps[id].estimatedValueUSD = estValue;
        rfps[id].awardedValueUSD = FHE.asEuint64(0);
        rfps[id].technicalWeightBps = techWeight;
        rfps[id].priceWeightBps = priceWeight;
        rfps[id].awardedVendor = address(0);
        rfps[id].status = AwardStatus.Open;
        rfps[id].proposalDeadline = block.timestamp + deadlineDays * 1 days;
        FHE.allowThis(rfps[id].estimatedValueUSD);
        FHE.allowThis(rfps[id].awardedValueUSD);
        FHE.allowThis(rfps[id].technicalWeightBps);
        FHE.allowThis(rfps[id].priceWeightBps);
        emit RFPPublished(id, rfpNumber, category);
    }

    function submitBid(
        uint256 rfpId,
        externalEuint64 encBidPrice, bytes calldata bpProof,
        externalEuint16 encTechScore, bytes calldata tsProof,
        externalEuint16 encDiversity, bytes calldata divProof,
        externalEuint8 encSecPosture, bytes calldata spProof
    ) external whenNotPaused returns (uint256 bidId) {
        DefenseRFP storage r = rfps[rfpId];
        require(r.status == AwardStatus.Open && block.timestamp < r.proposalDeadline, "RFP closed");
        require(uint8(vendorClearance[msg.sender]) >= uint8(r.minClearance), "Insufficient clearance");
        euint64 bidPrice = FHE.fromExternal(encBidPrice, bpProof);
        euint16 techScore = FHE.fromExternal(encTechScore, tsProof);
        euint16 diversity = FHE.fromExternal(encDiversity, divProof);
        euint8 secPosture = FHE.fromExternal(encSecPosture, spProof);
        bidId = bidCount++;
        vendorBids[bidId] = VendorBid({
            rfpId: rfpId, vendor: msg.sender, vendorClearance: vendorClearance[msg.sender],
            totalBidPriceUSD: bidPrice, technicalScoreBps: techScore,
            diversityScoreBps: diversity, securityPostureScore: secPosture, accepted: false
        });
        FHE.allowThis(vendorBids[bidId].totalBidPriceUSD); FHE.allow(vendorBids[bidId].totalBidPriceUSD, msg.sender);
        FHE.allowThis(vendorBids[bidId].technicalScoreBps); FHE.allow(vendorBids[bidId].technicalScoreBps, msg.sender);
        FHE.allowThis(vendorBids[bidId].diversityScoreBps);
        FHE.allowThis(vendorBids[bidId].securityPostureScore);
        emit BidSubmitted(bidId, rfpId);
    }

    function awardContract(uint256 rfpId, uint256 winningBidId) external onlyProcurementOfficer nonReentrant {
        DefenseRFP storage r = rfps[rfpId];
        VendorBid storage wb = vendorBids[winningBidId];
        require(r.status == AwardStatus.EvaluationPhase && wb.rfpId == rfpId, "Invalid state");
        r.awardedValueUSD = wb.totalBidPriceUSD;
        r.awardedVendor = wb.vendor;
        r.status = AwardStatus.Awarded;
        wb.accepted = true;
        _totalContractValueAwardedUSD = FHE.add(_totalContractValueAwardedUSD, wb.totalBidPriceUSD);
        FHE.allowThis(r.awardedValueUSD); FHE.allow(r.awardedValueUSD, wb.vendor);
        FHE.allowThis(_totalContractValueAwardedUSD);
        emit ContractAwarded(rfpId, wb.vendor);
    }

    function moveToEvaluation(uint256 rfpId) external onlyProcurementOfficer {
        rfps[rfpId].status = AwardStatus.EvaluationPhase;
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalContractValueAwardedUSD, viewer);
    }
}
