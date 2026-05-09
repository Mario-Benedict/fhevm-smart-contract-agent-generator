// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedHighwayConstructionBid
/// @notice Government highway infrastructure tender: encrypted contractor bids,
///         encrypted equipment rates, and encrypted penalty clause amounts.
contract EncryptedHighwayConstructionBid is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum RoadType { Motorway, Express, NationalHighway, StateRoad, RuralRoad }
    enum ContractPackage { Earthworks, Pavement, Structures, Drainage, Signage, AllIn }
    enum TenderStatus { Open, Evaluation, Awarded, Protested, Cancelled }

    struct HighwayProject {
        address governmentAuthority;
        string projectCode;
        RoadType roadType;
        string routeDescription;
        euint32 lengthKm;                 // encrypted route length
        euint64 engineerEstimateUSD;      // encrypted engineer's estimate
        euint64 contingencyPercBps;       // encrypted contingency %
        euint64 performanceBondUSD;       // encrypted required bond
        euint64 liquidatedDamagesPerDay;  // encrypted LD rate
        uint256 tenderClose;
        TenderStatus status;
        uint256 winningBidId;
    }

    struct ContractorBid {
        uint256 projectId;
        address contractor;
        ContractPackage pkg;
        euint64 totalBidUSD;              // encrypted total bid price
        euint64 mobilizationCostUSD;      // encrypted mobilization
        euint64 plantAndEquipmentUSD;     // encrypted equipment cost
        euint64 laborCostUSD;             // encrypted labor
        euint32 proposedDuration;         // encrypted days to complete
        euint32 technicalScore;           // encrypted technical evaluation
        bool disqualified;
    }

    mapping(uint256 => HighwayProject) private projects;
    mapping(uint256 => ContractorBid) private bids;
    mapping(uint256 => uint256[]) private projectBids;
    mapping(address => bool) public isGovernmentAuthority;
    mapping(address => bool) public isContractor;
    mapping(address => bool) public isTenderEvaluator;

    uint256 public projectCount;
    uint256 public bidCount;
    euint64 private _totalHighwayValueUSD;
    euint64 private _totalAwardedValueUSD;

    event ProjectPublished(uint256 indexed id, string code, RoadType rType);
    event BidSubmitted(uint256 indexed bidId, uint256 projectId, address contractor);
    event ContractAwarded(uint256 indexed projectId, address contractor);

    modifier onlyEvaluator() {
        require(isTenderEvaluator[msg.sender] || msg.sender == owner(), "Not evaluator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalHighwayValueUSD = FHE.asEuint64(0);
        _totalAwardedValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalHighwayValueUSD);
        FHE.allowThis(_totalAwardedValueUSD);
        isGovernmentAuthority[msg.sender] = true;
        isTenderEvaluator[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isGovernmentAuthority[a] = true; }
    function addContractor(address c) external onlyOwner { isContractor[c] = true; }
    function addEvaluator(address e) external onlyOwner { isTenderEvaluator[e] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function publishProject(
        string calldata code, RoadType rType, string calldata route,
        externalEuint32 encLength, bytes calldata lProof,
        externalEuint64 encEstimate, bytes calldata eProof,
        externalEuint64 encContingency, bytes calldata cProof,
        externalEuint64 encBond, bytes calldata bProof,
        externalEuint64 encLD, bytes calldata ldProof,
        uint256 tenderDays
    ) external whenNotPaused returns (uint256 id) {
        require(isGovernmentAuthority[msg.sender], "Not authority");
        euint32 length = FHE.fromExternal(encLength, lProof);
        euint64 estimate = FHE.fromExternal(encEstimate, eProof);
        euint64 contingency = FHE.fromExternal(encContingency, cProof);
        euint64 bond = FHE.fromExternal(encBond, bProof);
        euint64 ld = FHE.fromExternal(encLD, ldProof);
        id = projectCount++;
        HighwayProject storage _s0 = projects[id];
        _s0.governmentAuthority = msg.sender;
        _s0.projectCode = code;
        _s0.roadType = rType;
        _s0.routeDescription = route;
        _s0.lengthKm = length;
        _s0.engineerEstimateUSD = estimate;
        _s0.contingencyPercBps = contingency;
        _s0.performanceBondUSD = bond;
        _s0.liquidatedDamagesPerDay = ld;
        _s0.tenderClose = block.timestamp + tenderDays * 1 days;
        _s0.status = TenderStatus.Open;
        _s0.winningBidId = type(uint256).max;
        _totalHighwayValueUSD = FHE.add(_totalHighwayValueUSD, estimate);
        FHE.allowThis(projects[id].lengthKm);
        FHE.allowThis(projects[id].engineerEstimateUSD);
        FHE.allowThis(projects[id].contingencyPercBps);
        FHE.allowThis(projects[id].performanceBondUSD); FHE.allow(projects[id].performanceBondUSD, msg.sender);
        FHE.allowThis(projects[id].liquidatedDamagesPerDay);
        FHE.allowThis(_totalHighwayValueUSD);
        emit ProjectPublished(id, code, rType);
    }

    function submitBid(
        uint256 projectId, ContractPackage pkg,
        externalEuint64 encTotal, bytes calldata tProof,
        externalEuint64 encMobilization, bytes calldata mProof,
        externalEuint64 encPlant, bytes calldata pProof,
        externalEuint64 encLabor, bytes calldata lProof,
        externalEuint32 encDuration, bytes calldata dProof,
        externalEuint32 encTechScore, bytes calldata tsProof
    ) external whenNotPaused nonReentrant returns (uint256 bidId) {
        require(isContractor[msg.sender], "Not contractor");
        HighwayProject storage p = projects[projectId];
        require(p.status == TenderStatus.Open && block.timestamp < p.tenderClose, "Not open");
        euint64 total = FHE.fromExternal(encTotal, tProof);
        euint64 mob = FHE.fromExternal(encMobilization, mProof);
        euint64 plant = FHE.fromExternal(encPlant, pProof);
        euint64 labor = FHE.fromExternal(encLabor, lProof);
        euint32 duration = FHE.fromExternal(encDuration, dProof);
        euint32 techScore = FHE.fromExternal(encTechScore, tsProof);
        bidId = bidCount++;
        bids[bidId].projectId = projectId;
        bids[bidId].contractor = msg.sender;
        bids[bidId].pkg = pkg;
        bids[bidId].totalBidUSD = total;
        bids[bidId].mobilizationCostUSD = mob;
        bids[bidId].plantAndEquipmentUSD = plant;
        bids[bidId].laborCostUSD = labor;
        bids[bidId].proposedDuration = duration;
        bids[bidId].technicalScore = techScore;
        bids[bidId].disqualified = false;
        projectBids[projectId].push(bidId);
        FHE.allowThis(bids[bidId].totalBidUSD); FHE.allow(bids[bidId].totalBidUSD, msg.sender);
        FHE.allowThis(bids[bidId].mobilizationCostUSD); FHE.allow(bids[bidId].mobilizationCostUSD, msg.sender);
        FHE.allowThis(bids[bidId].plantAndEquipmentUSD); FHE.allow(bids[bidId].plantAndEquipmentUSD, msg.sender);
        FHE.allowThis(bids[bidId].laborCostUSD); FHE.allow(bids[bidId].laborCostUSD, msg.sender);
        FHE.allowThis(bids[bidId].proposedDuration); FHE.allow(bids[bidId].proposedDuration, msg.sender);
        FHE.allowThis(bids[bidId].technicalScore);
        emit BidSubmitted(bidId, projectId, msg.sender);
    }

    function awardContract(uint256 projectId, uint256 winningBidId) external onlyEvaluator nonReentrant {
        HighwayProject storage p = projects[projectId];
        require(p.status == TenderStatus.Open && block.timestamp >= p.tenderClose, "Not ended");
        ContractorBid storage b = bids[winningBidId];
        require(b.projectId == projectId && !b.disqualified, "Invalid bid");
        p.status = TenderStatus.Awarded;
        p.winningBidId = winningBidId;
        _totalAwardedValueUSD = FHE.add(_totalAwardedValueUSD, b.totalBidUSD);
        FHE.allow(b.totalBidUSD, p.governmentAuthority);
        FHE.allow(b.proposedDuration, p.governmentAuthority);
        FHE.allowThis(_totalAwardedValueUSD);
        emit ContractAwarded(projectId, b.contractor);
    }

    function disqualifyBid(uint256 bidId) external onlyEvaluator { bids[bidId].disqualified = true; }

    function allowInfraStats(address viewer) external onlyOwner {
        FHE.allow(_totalHighwayValueUSD, viewer);
        FHE.allow(_totalAwardedValueUSD, viewer);
    }
}
