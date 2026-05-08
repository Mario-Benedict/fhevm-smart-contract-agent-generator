// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedAircraftMaintenanceBid
/// @notice MRO (Maintenance, Repair & Overhaul) shops submit encrypted bids for
///         aircraft maintenance contracts. Encrypted labor rates and part costs stay confidential.
contract EncryptedAircraftMaintenanceBid is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum MaintenanceType { LineCheck, ACheck, BCheck, CCheck, DCheck, EngineOverhaul }
    enum TenderStatus { Open, Evaluation, Awarded, Cancelled }

    struct MaintenanceTender {
        address airline;
        string aircraftReg;           // aircraft registration
        string aircraftType;          // e.g. "B737-800"
        MaintenanceType mxType;
        euint64 estimatedBudgetUSD;   // encrypted budget
        euint32 turnaroundDays;       // encrypted max TAT allowed
        euint32 requiredCertification;// encrypted certification level
        uint256 submissionDeadline;
        TenderStatus status;
        uint256 winningBidId;
    }

    struct MROBid {
        uint256 tenderId;
        address mroShop;
        euint64 laborCostUSD;         // encrypted labor cost
        euint64 partsCostUSD;         // encrypted estimated parts
        euint64 totalBidUSD;          // encrypted total bid
        euint32 proposedTAT;          // encrypted turnaround time
        euint32 qualityScore;         // encrypted quality certification
        bool disqualified;
    }

    mapping(uint256 => MaintenanceTender) private tenders;
    mapping(uint256 => MROBid) private bids;
    mapping(address => bool) public isAirline;
    mapping(address => bool) public isMROShop;
    mapping(address => bool) public isEvaluator;

    uint256 public tenderCount;
    uint256 public bidCount;
    euint64 private _totalContractValueUSD;

    event TenderIssued(uint256 indexed id, string acReg, MaintenanceType mxType);
    event BidSubmitted(uint256 indexed bidId, uint256 tenderId, address mro);
    event ContractAwarded(uint256 indexed tenderId, address mro);

    modifier onlyEvaluator() {
        require(isEvaluator[msg.sender] || msg.sender == owner(), "Not evaluator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalContractValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalContractValueUSD);
        isEvaluator[msg.sender] = true;
    }

    function registerAirline(address a) external onlyOwner { isAirline[a] = true; }
    function registerMRO(address m) external onlyOwner { isMROShop[m] = true; }
    function addEvaluator(address e) external onlyOwner { isEvaluator[e] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function issueTender(
        string calldata acReg, string calldata acType, MaintenanceType mxType,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint32 encTAT, bytes calldata tProof,
        externalEuint32 encCert, bytes calldata cProof,
        uint256 deadlineDays
    ) external whenNotPaused returns (uint256 id) {
        require(isAirline[msg.sender], "Not airline");
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        euint32 tat = FHE.fromExternal(encTAT, tProof);
        euint32 cert = FHE.fromExternal(encCert, cProof);
        id = tenderCount++;
        tenders[id] = MaintenanceTender({
            airline: msg.sender, aircraftReg: acReg, aircraftType: acType, mxType: mxType,
            estimatedBudgetUSD: budget, turnaroundDays: tat, requiredCertification: cert,
            submissionDeadline: block.timestamp + deadlineDays * 1 days,
            status: TenderStatus.Open, winningBidId: type(uint256).max
        });
        FHE.allowThis(tenders[id].estimatedBudgetUSD);
        FHE.allowThis(tenders[id].turnaroundDays);
        FHE.allowThis(tenders[id].requiredCertification);
        emit TenderIssued(id, acReg, mxType);
    }

    function submitBid(
        uint256 tenderId,
        externalEuint64 encLabor, bytes calldata lProof,
        externalEuint64 encParts, bytes calldata pProof,
        externalEuint32 encTAT, bytes calldata tProof,
        externalEuint32 encQuality, bytes calldata qProof
    ) external whenNotPaused nonReentrant returns (uint256 bidId) {
        require(isMROShop[msg.sender], "Not MRO shop");
        MaintenanceTender storage t = tenders[tenderId];
        require(t.status == TenderStatus.Open && block.timestamp < t.submissionDeadline, "Closed");
        euint64 labor = FHE.fromExternal(encLabor, lProof);
        euint64 parts = FHE.fromExternal(encParts, pProof);
        euint32 tat = FHE.fromExternal(encTAT, tProof);
        euint32 quality = FHE.fromExternal(encQuality, qProof);
        euint64 total = FHE.add(labor, parts);
        ebool withinBudget = FHE.le(total, t.estimatedBudgetUSD);
        euint64 validTotal = FHE.select(withinBudget, total, FHE.asEuint64(type(uint64).max));
        bidId = bidCount++;
        bids[bidId] = MROBid({
            tenderId: tenderId, mroShop: msg.sender,
            laborCostUSD: labor, partsCostUSD: parts, totalBidUSD: validTotal,
            proposedTAT: tat, qualityScore: quality, disqualified: false
        });
        FHE.allowThis(bids[bidId].laborCostUSD); FHE.allow(bids[bidId].laborCostUSD, msg.sender);
        FHE.allowThis(bids[bidId].partsCostUSD); FHE.allow(bids[bidId].partsCostUSD, msg.sender);
        FHE.allowThis(bids[bidId].totalBidUSD); FHE.allow(bids[bidId].totalBidUSD, msg.sender);
        FHE.allowThis(bids[bidId].proposedTAT); FHE.allow(bids[bidId].proposedTAT, msg.sender);
        FHE.allowThis(bids[bidId].qualityScore);
        emit BidSubmitted(bidId, tenderId, msg.sender);
    }

    function awardContract(uint256 tenderId, uint256 winningBidId) external onlyEvaluator nonReentrant {
        MaintenanceTender storage t = tenders[tenderId];
        require(t.status == TenderStatus.Open && block.timestamp >= t.submissionDeadline, "Not ended");
        MROBid storage b = bids[winningBidId];
        require(b.tenderId == tenderId && !b.disqualified, "Invalid bid");
        t.status = TenderStatus.Awarded;
        t.winningBidId = winningBidId;
        _totalContractValueUSD = FHE.add(_totalContractValueUSD, b.totalBidUSD);
        FHE.allow(b.totalBidUSD, t.airline);
        FHE.allow(b.totalBidUSD, b.mroShop);
        FHE.allowThis(_totalContractValueUSD);
        emit ContractAwarded(tenderId, b.mroShop);
    }

    function disqualifyBid(uint256 bidId) external onlyEvaluator { bids[bidId].disqualified = true; }

    function allowMROStats(address viewer) external onlyOwner {
        FHE.allow(_totalContractValueUSD, viewer);
    }
}
