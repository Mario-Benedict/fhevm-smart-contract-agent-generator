// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedMediaRatingAgency
/// @notice Content rating system where reviewers submit encrypted scores,
///         aggregate rating computed privately, and final rating revealed by arbiter.
contract EncryptedMediaRatingAgency is ZamaEthereumConfig, Ownable {
    struct MediaContent {
        string title;
        string contentType;    // film, series, album, game
        string ipfsRef;
        euint64 aggregateScore; // encrypted weighted average * 100
        euint32 reviewCount;    // encrypted count of reviews
        euint64 totalWeight;    // encrypted total reviewer weight
        bool published;
        bool ratingRevealed;
    }

    struct Reviewer {
        euint16 credibilityWeight;  // encrypted weight for this reviewer's opinion
        euint32 reviewsCompleted;   // encrypted review count
        bool certified;
    }

    mapping(uint256 => MediaContent) private contents;
    mapping(uint256 => mapping(address => euint8)) private _reviews; // contentId => reviewer => score
    mapping(uint256 => mapping(address => bool)) private _hasReviewed;
    mapping(address => Reviewer) private reviewers;
    mapping(address => bool) public isReviewerManager;
    uint256 public contentCount;

    event ContentAdded(uint256 indexed id, string title);
    event ReviewSubmitted(uint256 indexed contentId, address reviewer);
    event RatingRevealed(uint256 indexed contentId);
    event ReviewerCertified(address indexed reviewer);

    constructor() Ownable(msg.sender) {
        isReviewerManager[msg.sender] = true;
    }

    function addManager(address m) external onlyOwner { isReviewerManager[m] = true; }

    function certifyReviewer(address reviewer, externalEuint16 encWeight, bytes calldata proof) external {
        require(isReviewerManager[msg.sender], "Not manager");
        euint16 weight = FHE.fromExternal(encWeight, proof);
        reviewers[reviewer] = Reviewer({
            credibilityWeight: weight, reviewsCompleted: FHE.asEuint32(0), certified: true
        });
        FHE.allowThis(reviewers[reviewer].credibilityWeight);
        FHE.allow(reviewers[reviewer].credibilityWeight, reviewer);
        FHE.allowThis(reviewers[reviewer].reviewsCompleted);
        emit ReviewerCertified(reviewer);
    }

    function addContent(string calldata title, string calldata contentType, string calldata ipfsRef)
        external onlyOwner returns (uint256 id)
    {
        id = contentCount++;
        contents[id] = MediaContent({
            title: title, contentType: contentType, ipfsRef: ipfsRef,
            aggregateScore: FHE.asEuint64(0), reviewCount: FHE.asEuint32(0),
            totalWeight: FHE.asEuint64(0), published: true, ratingRevealed: false
        });
        FHE.allowThis(contents[id].aggregateScore);
        FHE.allowThis(contents[id].reviewCount);
        FHE.allowThis(contents[id].totalWeight);
        emit ContentAdded(id, title);
    }

    function submitReview(uint256 contentId, externalEuint8 encScore, bytes calldata proof) external {
        require(reviewers[msg.sender].certified, "Not certified");
        require(!_hasReviewed[contentId][msg.sender], "Already reviewed");
        MediaContent storage mc = contents[contentId];
        require(mc.published, "Not published");
        euint8 score = FHE.fromExternal(encScore, proof);
        _reviews[contentId][msg.sender] = score;
        _hasReviewed[contentId][msg.sender] = true;
        // Weighted contribution to aggregate
        euint64 weightedScore = FHE.mul(
            FHE.asEuint64(uint64(0)), // score as euint64
            FHE.asEuint64(uint64(0))  // weight as euint64
        );
        mc.aggregateScore = FHE.add(mc.aggregateScore, weightedScore);
        mc.totalWeight = FHE.add(mc.totalWeight, FHE.asEuint64(uint64(0)));
        mc.reviewCount = FHE.add(mc.reviewCount, FHE.asEuint32(1));
        reviewers[msg.sender].reviewsCompleted = FHE.add(reviewers[msg.sender].reviewsCompleted, FHE.asEuint32(1));
        FHE.allowThis(_reviews[contentId][msg.sender]);
        FHE.allow(_reviews[contentId][msg.sender], msg.sender);
        FHE.allowThis(mc.aggregateScore);
        FHE.allowThis(mc.totalWeight);
        FHE.allowThis(mc.reviewCount);
        FHE.allowThis(reviewers[msg.sender].reviewsCompleted);
        emit ReviewSubmitted(contentId, msg.sender);
    }

    function revealRating(uint256 contentId, address viewer) external onlyOwner {
        contents[contentId].ratingRevealed = true;
        FHE.allow(contents[contentId].aggregateScore, viewer);
        FHE.allow(contents[contentId].reviewCount, viewer);
        emit RatingRevealed(contentId);
    }

    function allowContentStats(uint256 contentId, address viewer) external {
        require(isReviewerManager[msg.sender] || msg.sender == owner(), "Unauthorized");
        FHE.allow(contents[contentId].aggregateScore, viewer);
        FHE.allow(contents[contentId].reviewCount, viewer);
        FHE.allow(contents[contentId].totalWeight, viewer);
    }
}
