// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateAircraftMaintenanceBid
/// @notice MRO (Maintenance, Repair & Overhaul) sealed bidding: encrypted labor cost estimates,
///         encrypted parts pricing, encrypted turnaround time bids, and confidential airline scoring.
contract PrivateAircraftMaintenanceBid is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    struct MaintenanceRFP {
        string aircraftTailNumber;
        string maintenanceType; // e.g. "C-Check", "Engine Overhaul", "Line Maintenance"
        uint256 submissionDeadline;
        uint256 awardedTo;
        bool awarded;
        bool cancelled;
    }

    struct MROBid {
        uint256 rfpId;
        address mroProvider;
        euint64 laborCostUSD;      // encrypted labor estimate
        euint64 partsCostUSD;      // encrypted parts cost
        euint64 turnaroundDays;    // encrypted TAT in days
        euint64 qualityScoreBps;   // encrypted quality score out of 10000
        euint64 totalBidUSD;       // encrypted total bid
        bool submitted;
        bool disqualified;
    }

    struct MROProfile {
        euint64 pastPerformanceScore; // encrypted historical score
        euint64 capacityAvailable;    // encrypted available hangar capacity
        bool approved;
    }

    mapping(uint256 => MaintenanceRFP) private rfps;
    mapping(uint256 => MROBid) private bids;
    mapping(address => MROProfile) private mroProfiles;
    mapping(uint256 => uint256[]) private rfpBidIds;
    uint256 public rfpCount;
    uint256 public bidCount;
    mapping(address => bool) public isProcurementOfficer;

    event RFPCreated(uint256 indexed rfpId, string tailNumber, string maintenanceType);
    event BidSubmitted(uint256 indexed bidId, uint256 rfpId, address mro);
    event BidAwarded(uint256 indexed rfpId, uint256 winningBidId);
    event BidDisqualified(uint256 indexed bidId);
    event MROApproved(address indexed mro);

    constructor() Ownable(msg.sender) {
        isProcurementOfficer[msg.sender] = true;
    }

    function addOfficer(address o) external onlyOwner { isProcurementOfficer[o] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function approveMRO(
        address mro,
        externalEuint64 encPerfScore, bytes calldata psProof,
        externalEuint64 encCapacity, bytes calldata capProof
    ) external {
        require(isProcurementOfficer[msg.sender], "Not officer");
        euint64 perf = FHE.fromExternal(encPerfScore, psProof);
        euint64 cap = FHE.fromExternal(encCapacity, capProof);
        mroProfiles[mro] = MROProfile({
            pastPerformanceScore: perf, capacityAvailable: cap, approved: true
        });
        FHE.allowThis(mroProfiles[mro].pastPerformanceScore);
        FHE.allowThis(mroProfiles[mro].capacityAvailable);
        FHE.allow(mroProfiles[mro].pastPerformanceScore, mro);
        emit MROApproved(mro);
    }

    function createRFP(
        string calldata tailNumber,
        string calldata maintenanceType,
        uint256 submissionDeadline
    ) external whenNotPaused returns (uint256 rfpId) {
        require(isProcurementOfficer[msg.sender], "Not officer");
        rfpId = rfpCount++;
        rfps[rfpId] = MaintenanceRFP({
            aircraftTailNumber: tailNumber,
            maintenanceType: maintenanceType,
            submissionDeadline: submissionDeadline,
            awardedTo: 0,
            awarded: false,
            cancelled: false
        });
        emit RFPCreated(rfpId, tailNumber, maintenanceType);
    }

    function submitBid(
        uint256 rfpId,
        externalEuint64 encLabor, bytes calldata lProof,
        externalEuint64 encParts, bytes calldata pProof,
        externalEuint64 encTAT, bytes calldata tatProof,
        externalEuint64 encQuality, bytes calldata qProof
    ) external whenNotPaused nonReentrant returns (uint256 bidId) {
        require(mroProfiles[msg.sender].approved, "Not approved MRO");
        MaintenanceRFP storage rfp = rfps[rfpId];
        require(!rfp.awarded && !rfp.cancelled, "RFP closed");
        require(block.timestamp < rfp.submissionDeadline, "Deadline passed");
        euint64 labor = FHE.fromExternal(encLabor, lProof);
        euint64 parts = FHE.fromExternal(encParts, pProof);
        euint64 tat = FHE.fromExternal(encTAT, tatProof);
        euint64 quality = FHE.fromExternal(encQuality, qProof);
        euint64 total = FHE.add(labor, parts);
        bidId = bidCount++;
        bids[bidId].rfpId = rfpId;
        bids[bidId].mroProvider = msg.sender;
        bids[bidId].laborCostUSD = labor;
        bids[bidId].partsCostUSD = parts;
        bids[bidId].turnaroundDays = tat;
        bids[bidId].qualityScoreBps = quality;
        bids[bidId].totalBidUSD = total;
        bids[bidId].submitted = true;
        bids[bidId].disqualified = false;
        rfpBidIds[rfpId].push(bidId);
        FHE.allowThis(bids[bidId].laborCostUSD);
        FHE.allowThis(bids[bidId].partsCostUSD);
        FHE.allowThis(bids[bidId].turnaroundDays);
        FHE.allowThis(bids[bidId].qualityScoreBps);
        FHE.allowThis(bids[bidId].totalBidUSD);
        emit BidSubmitted(bidId, rfpId, msg.sender);
    }

    function awardBid(uint256 rfpId, uint256 winningBidId) external nonReentrant {
        require(isProcurementOfficer[msg.sender], "Not officer");
        MaintenanceRFP storage rfp = rfps[rfpId];
        require(!rfp.awarded && block.timestamp >= rfp.submissionDeadline, "Not ready");
        require(!bids[winningBidId].disqualified, "Disqualified bid");
        rfp.awarded = true;
        rfp.awardedTo = winningBidId;
        // Grant winner access to their own bid details
        address winner = bids[winningBidId].mroProvider;
        FHE.allow(bids[winningBidId].totalBidUSD, winner);
        FHE.allow(bids[winningBidId].turnaroundDays, winner);
        emit BidAwarded(rfpId, winningBidId);
    }

    function disqualifyBid(uint256 bidId) external {
        require(isProcurementOfficer[msg.sender], "Not officer");
        bids[bidId].disqualified = true;
        emit BidDisqualified(bidId);
    }

    function allowOfficerView(uint256 bidId, address officer) external {
        require(isProcurementOfficer[msg.sender], "Not officer");
        FHE.allow(bids[bidId].totalBidUSD, officer);
        FHE.allow(bids[bidId].turnaroundDays, officer);
        FHE.allow(bids[bidId].qualityScoreBps, officer);
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