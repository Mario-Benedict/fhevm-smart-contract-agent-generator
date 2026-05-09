// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCollaborativeResearchGrant
/// @notice Multi-institution research grant management: encrypted budget allocations per institution,
///         encrypted overhead rates, encrypted deliverable milestones, and private peer-review scoring.
contract PrivateCollaborativeResearchGrant is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Grant {
        string grantNumber;
        string researchArea;
        euint64 totalBudgetUSD;       // encrypted total budget
        euint64 allocatedUSD;         // encrypted total allocated
        euint64 disbursedUSD;         // encrypted total disbursed
        euint64 overheadPoolUSD;      // encrypted overhead pool
        uint256 startDate;
        uint256 endDate;
        bool active;
    }

    struct InstitutionAllocation {
        uint256 grantId;
        address institution;
        euint64 allocatedUSD;         // encrypted allocated budget
        euint64 overheadRateBps;      // encrypted overhead rate
        euint64 disbursedUSD;         // encrypted amount disbursed
        euint64 deliverableScore;     // encrypted deliverable performance 0-100
        bool active;
    }

    struct PeerReviewPanel {
        uint256 grantId;
        euint64 scientificScore;      // encrypted scientific merit 0-100
        euint64 feasibilityScore;     // encrypted feasibility 0-100
        euint64 impactScore;          // encrypted societal impact 0-100
        euint64 finalRecommendation;  // encrypted composite score
        bool completed;
    }

    mapping(uint256 => Grant) private grants;
    mapping(bytes32 => InstitutionAllocation) private allocations; // keccak(grantId, institution)
    mapping(uint256 => PeerReviewPanel) private reviews;
    uint256 public grantCount;
    euint64 private _totalGrantPool;
    mapping(address => bool) public isProgramOfficer;
    mapping(address => bool) public isPeerReviewer;

    event GrantCreated(uint256 indexed id, string grantNumber, string area);
    event InstitutionAllocated(uint256 indexed grantId, address institution);
    event FundsDisbursed(uint256 indexed grantId, address institution);
    event ReviewCompleted(uint256 indexed grantId);
    event DeliverableScoreUpdated(uint256 indexed grantId, address institution);

    constructor(externalEuint64 encPool, bytes memory proof) Ownable(msg.sender) {
        _totalGrantPool = FHE.fromExternal(encPool, proof);
        FHE.allowThis(_totalGrantPool);
        isProgramOfficer[msg.sender] = true;
        isPeerReviewer[msg.sender] = true;
    }

    function addOfficer(address o) external onlyOwner { isProgramOfficer[o] = true; }
    function addReviewer(address r) external onlyOwner { isPeerReviewer[r] = true; }

    function createGrant(
        string calldata grantNumber, string calldata area,
        externalEuint64 encBudget, bytes calldata bProof,
        uint256 startDate, uint256 endDate
    ) external returns (uint256 id) {
        require(isProgramOfficer[msg.sender], "Not officer");
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        id = grantCount++;
        grants[id].grantNumber = grantNumber;
        grants[id].researchArea = area;
        grants[id].totalBudgetUSD = budget;
        grants[id].allocatedUSD = FHE.asEuint64(0);
        grants[id].disbursedUSD = FHE.asEuint64(0);
        grants[id].overheadPoolUSD = FHE.asEuint64(0);
        grants[id].startDate = startDate;
        grants[id].endDate = endDate;
        grants[id].active = true;
        _totalGrantPool = FHE.sub(_totalGrantPool, budget);
        FHE.allowThis(grants[id].totalBudgetUSD);
        FHE.allowThis(grants[id].allocatedUSD);
        FHE.allowThis(grants[id].disbursedUSD);
        FHE.allowThis(grants[id].overheadPoolUSD);
        FHE.allowThis(_totalGrantPool);
        emit GrantCreated(id, grantNumber, area);
    }

    function allocateToInstitution(
        uint256 grantId, address institution,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint64 encOverhead, bytes calldata oProof
    ) external {
        require(isProgramOfficer[msg.sender], "Not officer");
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint64 overhead = FHE.fromExternal(encOverhead, oProof);
        Grant storage g = grants[grantId];
        ebool withinBudget = FHE.le(FHE.add(g.allocatedUSD, amount), g.totalBudgetUSD);
        euint64 actual = FHE.select(withinBudget, amount, FHE.sub(g.totalBudgetUSD, g.allocatedUSD));
        bytes32 key = keccak256(abi.encodePacked(grantId, institution));
        allocations[key] = InstitutionAllocation({
            grantId: grantId, institution: institution,
            allocatedUSD: actual, overheadRateBps: overhead,
            disbursedUSD: FHE.asEuint64(0),
            deliverableScore: FHE.asEuint64(0), active: true
        });
        g.allocatedUSD = FHE.add(g.allocatedUSD, actual);
        // Overhead pool
        euint64 overheadAmount = FHE.div(FHE.mul(actual, overhead), 10000);
        g.overheadPoolUSD = FHE.add(g.overheadPoolUSD, overheadAmount);
        FHE.allowThis(allocations[key].allocatedUSD);
        FHE.allowThis(allocations[key].disbursedUSD);
        FHE.allowThis(allocations[key].deliverableScore);
        FHE.allow(allocations[key].allocatedUSD, institution);
        FHE.allowThis(g.allocatedUSD);
        FHE.allowThis(g.overheadPoolUSD);
        emit InstitutionAllocated(grantId, institution);
    }

    function disburseFunds(
        uint256 grantId, address institution,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        require(isProgramOfficer[msg.sender], "Not officer");
        bytes32 key = keccak256(abi.encodePacked(grantId, institution));
        InstitutionAllocation storage alloc = allocations[key];
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool withinAlloc = FHE.le(FHE.add(alloc.disbursedUSD, amount), alloc.allocatedUSD);
        euint64 actual = FHE.select(withinAlloc, amount, FHE.sub(alloc.allocatedUSD, alloc.disbursedUSD));
        alloc.disbursedUSD = FHE.add(alloc.disbursedUSD, actual);
        grants[grantId].disbursedUSD = FHE.add(grants[grantId].disbursedUSD, actual);
        FHE.allowThis(alloc.disbursedUSD);
        FHE.allow(alloc.disbursedUSD, institution);
        FHE.allowThis(grants[grantId].disbursedUSD);
        FHE.allow(actual, institution);
        emit FundsDisbursed(grantId, institution);
    }

    function conductPeerReview(
        uint256 grantId,
        externalEuint64 encScientific, bytes calldata sciProof,
        externalEuint64 encFeasibility, bytes calldata feasProof,
        externalEuint64 encImpact, bytes calldata impProof
    ) external {
        require(isPeerReviewer[msg.sender], "Not reviewer");
        euint64 sci = FHE.fromExternal(encScientific, sciProof);
        euint64 feas = FHE.fromExternal(encFeasibility, feasProof);
        euint64 imp = FHE.fromExternal(encImpact, impProof);
        // Composite: 40% scientific + 30% feasibility + 30% impact
        euint64 composite = FHE.div(
            FHE.add(FHE.add(FHE.mul(sci, 40), FHE.mul(feas, 30)), FHE.mul(imp, FHE.asEuint64(30))),
            100
        );
        reviews[grantId] = PeerReviewPanel({
            grantId: grantId, scientificScore: sci, feasibilityScore: feas,
            impactScore: imp, finalRecommendation: composite, completed: true
        });
        FHE.allowThis(reviews[grantId].scientificScore);
        FHE.allowThis(reviews[grantId].feasibilityScore);
        FHE.allowThis(reviews[grantId].impactScore);
        FHE.allowThis(reviews[grantId].finalRecommendation);
        FHE.allow(reviews[grantId].finalRecommendation, owner());
        emit ReviewCompleted(grantId);
    }

    function updateDeliverableScore(
        uint256 grantId, address institution,
        externalEuint64 encScore, bytes calldata proof
    ) external {
        require(isProgramOfficer[msg.sender], "Not officer");
        bytes32 key = keccak256(abi.encodePacked(grantId, institution));
        allocations[key].deliverableScore = FHE.fromExternal(encScore, proof);
        FHE.allowThis(allocations[key].deliverableScore);
        FHE.allow(allocations[key].deliverableScore, institution);
        emit DeliverableScoreUpdated(grantId, institution);
    }
}
