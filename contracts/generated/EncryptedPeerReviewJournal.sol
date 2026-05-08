// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title EncryptedPeerReviewJournal - Double-blind academic peer review with encrypted reviewer scores
contract EncryptedPeerReviewJournal is ZamaEthereumConfig, AccessControl {
    bytes32 public constant EDITOR_ROLE   = keccak256("EDITOR_ROLE");
    bytes32 public constant REVIEWER_ROLE = keccak256("REVIEWER_ROLE");
    bytes32 public constant AUTHOR_ROLE   = keccak256("AUTHOR_ROLE");

    enum DecisionStatus { UnderReview, MajorRevision, MinorRevision, Accepted, Rejected }

    struct Manuscript {
        string  ipfsCid;         // blinded manuscript
        string  fieldOfStudy;
        euint8  overallScore;    // aggregate reviewer score 0-100
        euint8  noveltyScore;
        euint8  methodologyScore;
        euint8  reviewerCount;
        DecisionStatus decision;
        bool    published;
        uint256 submittedAt;
        address submittedBy;
    }

    struct ReviewRecord {
        address reviewer;
        euint8  scoreNovelty;
        euint8  scoreMethodology;
        euint8  scoreClarity;
        euint8  recommendation; // 1=accept 2=minor 3=major 4=reject
        bool    submitted;
    }

    mapping(uint256 => Manuscript)   public manuscripts;
    mapping(uint256 => mapping(uint8 => ReviewRecord)) private reviews;
    mapping(uint256 => mapping(address => bool)) public assignedReviewer;
    mapping(uint256 => uint8) public reviewAssignmentCount;
    uint256 public manuscriptCount;

    event ManuscriptSubmitted(uint256 indexed msId, string field);
    event ReviewerAssigned(uint256 indexed msId, address indexed reviewer);
    event ReviewSubmitted(uint256 indexed msId, address indexed reviewer);
    event DecisionMade(uint256 indexed msId, DecisionStatus decision);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EDITOR_ROLE, msg.sender);
    }

    function submitManuscript(string calldata ipfsCid, string calldata field)
        external onlyRole(AUTHOR_ROLE) returns (uint256 msId)
    {
        msId = manuscriptCount++;
        Manuscript storage m = manuscripts[msId];
        m.ipfsCid       = ipfsCid;
        m.fieldOfStudy  = field;
        m.overallScore  = FHE.asEuint8(0);
        m.noveltyScore  = FHE.asEuint8(0);
        m.methodologyScore = FHE.asEuint8(0);
        m.reviewerCount = FHE.asEuint8(0);
        m.decision      = DecisionStatus.UnderReview;
        m.submittedAt   = block.timestamp;
        m.submittedBy   = msg.sender;
        FHE.allowThis(m.overallScore); FHE.allowThis(m.noveltyScore);
        FHE.allowThis(m.methodologyScore); FHE.allowThis(m.reviewerCount);
        emit ManuscriptSubmitted(msId, field);
    }

    function assignReviewer(uint256 msId, address reviewer) external onlyRole(EDITOR_ROLE) {
        require(hasRole(REVIEWER_ROLE, reviewer), "Not reviewer");
        require(!assignedReviewer[msId][reviewer], "Already assigned");
        assignedReviewer[msId][reviewer] = true;
        uint8 idx = reviewAssignmentCount[msId]++;
        reviews[msId][idx].reviewer = reviewer;
        emit ReviewerAssigned(msId, reviewer);
    }

    function submitReview(
        uint256 msId, uint8 reviewSlot,
        externalEuint8 calldata encNovelty,      bytes calldata noveltyProof,
        externalEuint8 calldata encMethodology,  bytes calldata methodProof,
        externalEuint8 calldata encClarity,      bytes calldata clarityProof,
        externalEuint8 calldata encRecommend,    bytes calldata recommendProof
    ) external onlyRole(REVIEWER_ROLE) {
        require(assignedReviewer[msId][msg.sender], "Not assigned");
        ReviewRecord storage r = reviews[msId][reviewSlot];
        require(r.reviewer == msg.sender && !r.submitted, "Invalid");
        r.scoreNovelty      = FHE.fromExternal(encNovelty,     noveltyProof);
        r.scoreMethodology  = FHE.fromExternal(encMethodology, methodProof);
        r.scoreClarity      = FHE.fromExternal(encClarity,     clarityProof);
        r.recommendation    = FHE.fromExternal(encRecommend,   recommendProof);
        r.submitted         = true;
        FHE.allowThis(r.scoreNovelty); FHE.allowThis(r.scoreMethodology);
        FHE.allowThis(r.scoreClarity); FHE.allowThis(r.recommendation);
        FHE.allow(r.scoreNovelty, getRoleAdmin(EDITOR_ROLE));
        Manuscript storage m = manuscripts[msId];
        euint8 avg = FHE.div(FHE.add(FHE.add(r.scoreNovelty, r.scoreMethodology), r.scoreClarity), FHE.asEuint8(3));
        m.overallScore = FHE.add(m.overallScore, avg);
        m.reviewerCount = FHE.add(m.reviewerCount, FHE.asEuint8(1));
        FHE.allowThis(m.overallScore); FHE.allowThis(m.reviewerCount);
        FHE.allow(m.overallScore, getRoleAdmin(EDITOR_ROLE));
        emit ReviewSubmitted(msId, msg.sender);
    }

    function makeDecision(uint256 msId, DecisionStatus decision) external onlyRole(EDITOR_ROLE) {
        manuscripts[msId].decision = decision;
        if (decision == DecisionStatus.Accepted) {
            manuscripts[msId].published = true;
            FHE.allow(manuscripts[msId].overallScore, manuscripts[msId].submittedBy);
        }
        emit DecisionMade(msId, decision);
    }
}
