// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AcademicPeerReview
/// @notice Double-blind peer review system: reviewers score papers anonymously
///         with encrypted scores; editors decide based on aggregated encrypted results.
contract AcademicPeerReview is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Paper {
        bytes32 contentHash;
        address author;
        string title;
        euint16 totalScore;       // sum of reviewer scores
        euint8 reviewerCount;
        euint8 averageScore;
        bool accepted;
        bool decided;
    }

    struct Review {
        euint8 technicalScore;  // 1-10
        euint8 noveltyScore;    // 1-10
        euint8 clarityScore;    // 1-10
        string comment;         // plaintext comment (optional)
        bool submitted;
    }

    mapping(uint256 => Paper) private papers;
    mapping(address => mapping(uint256 => Review)) private reviews;
    mapping(address => bool) public isReviewer;
    mapping(address => bool) public isEditor;
    uint256 public paperCount;
    euint8 private _acceptanceThreshold; // encrypted minimum avg score

    event PaperSubmitted(uint256 indexed paperId, address author);
    event ReviewSubmitted(uint256 indexed paperId, address reviewer);
    event DecisionMade(uint256 indexed paperId, bool accepted);

    constructor(externalEuint8 encThreshold, bytes memory proof) Ownable(msg.sender) {
        _acceptanceThreshold = FHE.fromExternal(encThreshold, proof);
        FHE.allowThis(_acceptanceThreshold);
        isEditor[msg.sender] = true;
    }

    function addReviewer(address r) external onlyOwner { isReviewer[r] = true; }
    function addEditor(address e) external onlyOwner { isEditor[e] = true; }

    function submitPaper(bytes32 contentHash, string calldata title) external returns (uint256 id) {
        id = paperCount++;
        papers[id] = Paper({
            contentHash: contentHash,
            author: msg.sender,
            title: title,
            totalScore: FHE.asEuint16(0),
            reviewerCount: FHE.asEuint8(0),
            averageScore: FHE.asEuint8(0),
            accepted: false,
            decided: false
        });
        FHE.allowThis(papers[id].totalScore);
        FHE.allowThis(papers[id].reviewerCount);
        FHE.allowThis(papers[id].averageScore);
        emit PaperSubmitted(id, msg.sender);
    }

    function submitReview(
        uint256 paperId,
        externalEuint8 encTech, bytes calldata tProof,
        externalEuint8 encNovelty, bytes calldata nProof,
        externalEuint8 encClarity, bytes calldata cProof,
        string calldata comment
    ) external nonReentrant {
        require(isReviewer[msg.sender], "Not reviewer");
        require(msg.sender != papers[paperId].author, "Cannot review own paper");
        require(!reviews[msg.sender][paperId].submitted, "Already reviewed");
        euint8 tech = FHE.fromExternal(encTech, tProof);
        euint8 novelty = FHE.fromExternal(encNovelty, nProof);
        euint8 clarity = FHE.fromExternal(encClarity, cProof);
        reviews[msg.sender][paperId] = Review({
            technicalScore: tech, noveltyScore: novelty, clarityScore: clarity,
            comment: comment, submitted: true
        });
        FHE.allowThis(reviews[msg.sender][paperId].technicalScore);
        FHE.allowThis(reviews[msg.sender][paperId].noveltyScore);
        FHE.allowThis(reviews[msg.sender][paperId].clarityScore);
        // Aggregate: average of 3 scores
        euint8 reviewScore = FHE.div(
            FHE.add(FHE.add(tech, novelty), clarity),
            3
        );
        papers[paperId].totalScore = FHE.add(papers[paperId].totalScore, FHE.asEuint16(uint16(0)));
        papers[paperId].reviewerCount = FHE.add(papers[paperId].reviewerCount, FHE.asEuint8(1));
        FHE.allowThis(papers[paperId].totalScore);
        FHE.allowThis(papers[paperId].reviewerCount);
        FHE.allowThis(reviewScore);
        emit ReviewSubmitted(paperId, msg.sender);
    }

    function makeDecision(uint256 paperId) external {
        require(isEditor[msg.sender], "Not editor");
        Paper storage p = papers[paperId];
        require(!p.decided, "Already decided");
        p.decided = true;
        // Accept if average score >= threshold
        ebool passes = FHE.ge(p.averageScore, _acceptanceThreshold);
        p.accepted = FHE.isInitialized(passes);
        FHE.allow(p.averageScore, p.author);
        emit DecisionMade(paperId, p.accepted);
    }

    function allowPaperScores(uint256 paperId, address viewer) external {
        require(isEditor[msg.sender], "Not editor");
        FHE.allow(papers[paperId].totalScore, viewer);
        FHE.allow(papers[paperId].averageScore, viewer);
    }
}
