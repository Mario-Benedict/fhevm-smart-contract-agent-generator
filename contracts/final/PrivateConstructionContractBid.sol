// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateConstructionContractBid
/// @notice Construction procurement: developers post projects, contractors submit
///         encrypted sealed bids, committee evaluates scores privately, winner selected.
contract PrivateConstructionContractBid is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ProjectStatus { Open, EvaluationPhase, Awarded, Cancelled }

    struct ConstructionProject {
        string projectName;
        string specifications;
        address developer;
        euint64 estimatedBudgetUSD;    // encrypted estimated budget
        euint64 winningBidUSD;         // encrypted winning bid
        euint8  qualityWeightBps;      // encrypted quality vs price weight
        uint256 bidDeadline;
        uint256 projectStartDate;
        uint256 completionDate;
        ProjectStatus status;
        address awardedContractor;
    }

    struct ContractorBid {
        euint64 bidAmountUSD;          // encrypted total bid
        euint64 materialsCostUSD;      // encrypted materials estimate
        euint64 laborCostUSD;          // encrypted labor estimate
        euint8  technicalScore;        // encrypted technical evaluation
        euint8  safetyScore;           // encrypted safety record score
        uint256 completionWeeks;
        bool submitted;
        bool disqualified;
    }

    mapping(uint256 => ConstructionProject) private projects;
    mapping(uint256 => mapping(address => ContractorBid)) private bids;
    mapping(address => bool) public isEvaluationCommittee;
    mapping(address => bool) public isLicensedContractor;
    uint256 public projectCount;
    euint64 private _totalAwardedValue;

    event ProjectPosted(uint256 indexed id, string name);
    event BidSubmitted(uint256 indexed projectId, address contractor);
    event EvaluationStarted(uint256 indexed projectId);
    event ContractAwarded(uint256 indexed projectId, address contractor);
    event BidDisqualified(uint256 indexed projectId, address contractor);

    modifier onlyCommittee() {
        require(isEvaluationCommittee[msg.sender] || msg.sender == owner(), "Not committee");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAwardedValue = FHE.asEuint64(0);
        FHE.allowThis(_totalAwardedValue);
        isEvaluationCommittee[msg.sender] = true;
    }

    function addCommitteeMember(address c) external onlyOwner { isEvaluationCommittee[c] = true; }
    function addContractor(address c) external onlyOwner { isLicensedContractor[c] = true; }

    function postProject(
        string calldata name, string calldata specs,
        externalEuint64 encBudget, bytes calldata bPf,
        externalEuint8 encQualityWeight, bytes calldata qPf,
        uint256 bidDeadlineDays, uint256 startDays, uint256 completionDays
    ) external returns (uint256 id) {
        euint64 budget = FHE.fromExternal(encBudget, bPf);
        euint8 qWeight = FHE.fromExternal(encQualityWeight, qPf);
        id = projectCount++;
        projects[id].projectName = name;
        projects[id].specifications = specs;
        projects[id].developer = msg.sender;
        projects[id].estimatedBudgetUSD = budget;
        projects[id].winningBidUSD = FHE.asEuint64(type(uint64).max);
        projects[id].qualityWeightBps = qWeight;
        projects[id].bidDeadline = block.timestamp + bidDeadlineDays * 1 days;
        projects[id].projectStartDate = block.timestamp + startDays * 1 days;
        projects[id].completionDate = block.timestamp + completionDays * 1 days;
        projects[id].status = ProjectStatus.Open;
        projects[id].awardedContractor = address(0);
        FHE.allowThis(projects[id].estimatedBudgetUSD);
        FHE.allow(projects[id].estimatedBudgetUSD, msg.sender);
        FHE.allowThis(projects[id].winningBidUSD);
        FHE.allowThis(projects[id].qualityWeightBps);
        emit ProjectPosted(id, name);
    }

    function submitBid(
        uint256 projectId,
        externalEuint64 encBidAmt, bytes calldata baPf,
        externalEuint64 encMaterials, bytes calldata mPf,
        externalEuint64 encLabor, bytes calldata lPf,
        externalEuint8 encTechScore, bytes calldata tPf,
        externalEuint8 encSafetyScore, bytes calldata sPf,
        uint256 completionWeeks
    ) external nonReentrant {
        require(isLicensedContractor[msg.sender], "Not licensed");
        ConstructionProject storage p = projects[projectId];
        require(p.status == ProjectStatus.Open && block.timestamp < p.bidDeadline, "Bidding closed");
        euint64 bidAmt = FHE.fromExternal(encBidAmt, baPf);
        euint64 materials = FHE.fromExternal(encMaterials, mPf);
        euint64 labor = FHE.fromExternal(encLabor, lPf);
        euint8 techScore = FHE.fromExternal(encTechScore, tPf);
        euint8 safetyScore = FHE.fromExternal(encSafetyScore, sPf);
        bids[projectId][msg.sender] = ContractorBid({
            bidAmountUSD: bidAmt, materialsCostUSD: materials, laborCostUSD: labor,
            technicalScore: techScore, safetyScore: safetyScore,
            completionWeeks: completionWeeks, submitted: true, disqualified: false
        });
        // Track lowest bid
        ebool isLowest = FHE.lt(bidAmt, p.winningBidUSD);
        if (FHE.isInitialized(isLowest)) {
            p.winningBidUSD = bidAmt;
            p.awardedContractor = msg.sender;
            FHE.allowThis(p.winningBidUSD);
        }
        FHE.allowThis(bids[projectId][msg.sender].bidAmountUSD);
        FHE.allow(bids[projectId][msg.sender].bidAmountUSD, msg.sender);
        FHE.allowThis(bids[projectId][msg.sender].technicalScore);
        FHE.allowThis(bids[projectId][msg.sender].safetyScore);
        FHE.allowThis(bids[projectId][msg.sender].materialsCostUSD);
        FHE.allowThis(bids[projectId][msg.sender].laborCostUSD);
        emit BidSubmitted(projectId, msg.sender);
    }

    function startEvaluation(uint256 projectId) external onlyCommittee {
        projects[projectId].status = ProjectStatus.EvaluationPhase;
        emit EvaluationStarted(projectId);
    }

    function awardContract(uint256 projectId, address contractor) external onlyCommittee {
        ConstructionProject storage p = projects[projectId];
        require(p.status == ProjectStatus.EvaluationPhase, "Not in evaluation");
        require(bids[projectId][contractor].submitted && !bids[projectId][contractor].disqualified, "Invalid bid");
        p.awardedContractor = contractor;
        p.winningBidUSD = bids[projectId][contractor].bidAmountUSD;
        p.status = ProjectStatus.Awarded;
        _totalAwardedValue = FHE.add(_totalAwardedValue, p.winningBidUSD);
        FHE.allowThis(_totalAwardedValue);
        FHE.allow(p.winningBidUSD, contractor);
        FHE.allow(p.winningBidUSD, p.developer);
        emit ContractAwarded(projectId, contractor);
    }

    function disqualifyBid(uint256 projectId, address contractor) external onlyCommittee {
        bids[projectId][contractor].disqualified = true;
        emit BidDisqualified(projectId, contractor);
    }

    function allowBidDetails(uint256 projectId, address contractor, address viewer) external onlyCommittee {
        FHE.allow(bids[projectId][contractor].bidAmountUSD, viewer);
        FHE.allow(bids[projectId][contractor].technicalScore, viewer);
        FHE.allow(bids[projectId][contractor].safetyScore, viewer);
    }

    function allowProjectStats(address viewer) external onlyOwner {
        FHE.allow(_totalAwardedValue, viewer);
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