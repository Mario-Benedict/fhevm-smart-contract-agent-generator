// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateDefenseContractorBidding
/// @notice Defense procurement sealed bidding: encrypted contractor capability scores,
///         encrypted classified technical requirements, encrypted lifecycle cost, and private ITAR compliance scoring.
contract PrivateDefenseContractorBidding is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SecurityClearance { NONE, CONFIDENTIAL, SECRET, TOP_SECRET, SCI }
    enum SystemType { WEAPON, SURVEILLANCE, LOGISTICS, COMMUNICATIONS, CYBER, AEROSPACE }

    struct ProcurementProgram {
        string programName;
        string classificationLevel;
        SystemType systemType;
        euint64 estimatedBudgetUSD;   // encrypted budget estimate
        euint64 technicalRequirements;// encrypted technical score threshold
        euint64 minCapabilityScore;   // encrypted minimum required score
        uint256 biddingDeadline;
        uint256 deliveryDate;
        bool awardDecided;
        bool classified;
    }

    struct ContractorBid {
        uint256 programId;
        address contractor;
        euint64 bidPriceUSD;          // encrypted total bid price
        euint64 lifecycleCostUSD;     // encrypted 20-year lifecycle cost
        euint64 technicalScore;       // encrypted technical evaluation score
        euint64 capabilityScore;      // encrypted past-performance capability
        euint64 itarComplianceScore;  // encrypted ITAR/export compliance score
        euint8 clearanceLevel;        // encrypted security clearance level
        bool disqualified;
        bool selected;
    }

    mapping(uint256 => ProcurementProgram) private programs;
    mapping(uint256 => ContractorBid) private bids;
    mapping(address => SecurityClearance) public contractorClearance;
    mapping(uint256 => uint256[]) private programBidIds;
    uint256 public programCount;
    uint256 public bidCount;
    mapping(address => bool) public isProcurementOfficer;
    mapping(address => bool) public isTechnicalEvaluator;

    event ProgramCreated(uint256 indexed id, string name, SystemType stype);
    event BidSubmitted(uint256 indexed bidId, uint256 programId, address contractor);
    event BidSelected(uint256 indexed bidId, uint256 programId);
    event BidDisqualified(uint256 indexed bidId, string reason);
    event ClearanceGranted(address indexed contractor, SecurityClearance level);

    constructor() Ownable(msg.sender) {
        isProcurementOfficer[msg.sender] = true;
        isTechnicalEvaluator[msg.sender] = true;
    }

    function addOfficer(address o) external onlyOwner { isProcurementOfficer[o] = true; }
    function addEvaluator(address e) external onlyOwner { isTechnicalEvaluator[e] = true; }

    function grantClearance(address contractor, SecurityClearance level) external onlyOwner {
        contractorClearance[contractor] = level;
        emit ClearanceGranted(contractor, level);
    }

    function createProgram(
        string calldata name, string calldata classification, SystemType stype,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint64 encTechReq, bytes calldata trProof,
        externalEuint64 encMinCap, bytes calldata mcProof,
        uint256 deadline, uint256 delivery
    ) external returns (uint256 id) {
        require(isProcurementOfficer[msg.sender], "Not officer");
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        euint64 techReq = FHE.fromExternal(encTechReq, trProof);
        euint64 minCap = FHE.fromExternal(encMinCap, mcProof);
        id = programCount++;
        programs[id].programName = name;
        programs[id].classificationLevel = classification;
        programs[id].systemType = stype;
        programs[id].estimatedBudgetUSD = budget;
        programs[id].technicalRequirements = techReq;
        programs[id].minCapabilityScore = minCap;
        programs[id].biddingDeadline = deadline;
        programs[id].deliveryDate = delivery;
        programs[id].awardDecided = false;
        programs[id].classified = true;
        FHE.allowThis(programs[id].estimatedBudgetUSD);
        FHE.allowThis(programs[id].technicalRequirements);
        FHE.allowThis(programs[id].minCapabilityScore);
        emit ProgramCreated(id, name, stype);
    }

    function submitBid(
        uint256 programId,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint64 encLifecycle, bytes calldata lcProof,
        externalEuint64 encTechScore, bytes calldata tsProof,
        externalEuint64 encCapability, bytes calldata capProof,
        externalEuint64 encITAR, bytes calldata itarProof,
        externalEuint8 encClearance, bytes calldata clProof
    ) external nonReentrant returns (uint256 bidId) {
        require(contractorClearance[msg.sender] >= SecurityClearance.SECRET, "Insufficient clearance");
        require(block.timestamp < programs[programId].biddingDeadline, "Deadline passed");
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint64 lifecycle = FHE.fromExternal(encLifecycle, lcProof);
        euint64 techScore = FHE.fromExternal(encTechScore, tsProof);
        euint64 capability = FHE.fromExternal(encCapability, capProof);
        euint64 itar = FHE.fromExternal(encITAR, itarProof);
        euint8 clearance = FHE.fromExternal(encClearance, clProof);
        bidId = bidCount++;
        bids[bidId].programId = programId;
        bids[bidId].contractor = msg.sender;
        bids[bidId].bidPriceUSD = price;
        bids[bidId].lifecycleCostUSD = lifecycle;
        bids[bidId].technicalScore = techScore;
        bids[bidId].capabilityScore = capability;
        bids[bidId].itarComplianceScore = itar;
        bids[bidId].clearanceLevel = clearance;
        bids[bidId].disqualified = false;
        bids[bidId].selected = false;
        programBidIds[programId].push(bidId);
        FHE.allowThis(bids[bidId].bidPriceUSD);
        FHE.allowThis(bids[bidId].lifecycleCostUSD);
        FHE.allowThis(bids[bidId].technicalScore);
        FHE.allowThis(bids[bidId].capabilityScore);
        FHE.allowThis(bids[bidId].itarComplianceScore);
        FHE.allowThis(bids[bidId].clearanceLevel);
        emit BidSubmitted(bidId, programId, msg.sender);
    }

    function evaluateBid(uint256 bidId) external view returns (bool) {
        require(isTechnicalEvaluator[msg.sender], "Not evaluator");
        // Evaluation results remain encrypted; officer can view
        return !bids[bidId].disqualified;
    }

    function selectWinner(uint256 programId, uint256 bidId) external {
        require(isProcurementOfficer[msg.sender], "Not officer");
        require(block.timestamp >= programs[programId].biddingDeadline, "Bidding open");
        require(!programs[programId].awardDecided, "Already decided");
        require(!bids[bidId].disqualified, "Disqualified");
        bids[bidId].selected = true;
        programs[programId].awardDecided = true;
        address winner = bids[bidId].contractor;
        FHE.allow(bids[bidId].bidPriceUSD, winner);
        FHE.allow(bids[bidId].lifecycleCostUSD, winner);
        emit BidSelected(bidId, programId);
    }

    function disqualifyBid(uint256 bidId, string calldata reason) external {
        require(isProcurementOfficer[msg.sender], "Not officer");
        bids[bidId].disqualified = true;
        emit BidDisqualified(bidId, reason);
    }

    function grantEvaluatorView(uint256 bidId, address evaluator) external {
        require(isProcurementOfficer[msg.sender], "Not officer");
        FHE.allow(bids[bidId].technicalScore, evaluator);
        FHE.allow(bids[bidId].capabilityScore, evaluator);
        FHE.allow(bids[bidId].itarComplianceScore, evaluator);
    }
}
