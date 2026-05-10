// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivateMessageBoard
/// @notice Encrypted on-chain message board: private message content references,
///         hidden upvote weights, confidential moderation scores, and encrypted
///         tip/reward distribution to content creators.
contract EncryptedPrivateMessageBoard is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Post {
        address author;
        string contentHash;             // IPFS hash (public) - content encrypted off-chain
        euint64 upvoteWeight;           // encrypted upvote score
        euint64 tipsReceivedUSD;        // encrypted tips
        euint16 moderationScore;        // encrypted moderation rating
        euint8  flagCount;              // encrypted flag count
        uint256 postedAt;
        bool removed;
    }

    struct UserProfile {
        euint64 reputationScore;        // encrypted reputation
        euint64 totalTipsEarnedUSD;     // encrypted earnings
        euint32 postCount;              // encrypted post count
        bool registered;
    }

    mapping(uint256 => Post) private posts;
    mapping(address => UserProfile) private profiles;
    mapping(address => bool) public isModerator;

    uint256 public postCount;
    euint64 private _totalTipsDistributed;
    euint64 private _totalPlatformRevenue;

    event PostPublished(uint256 indexed id, address author);
    event PostTipped(uint256 indexed id, address tipper, uint256 timestamp);
    event PostFlagged(uint256 indexed id, address flagger);
    event PostRemoved(uint256 indexed id);

    modifier onlyModerator() {
        require(isModerator[msg.sender] || msg.sender == owner(), "Not moderator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalTipsDistributed = FHE.asEuint64(0);
        _totalPlatformRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalTipsDistributed);
        FHE.allowThis(_totalPlatformRevenue);
        isModerator[msg.sender] = true;
    }

    function addModerator(address m) external onlyOwner { isModerator[m] = true; }

    function registerUser() external {
        profiles[msg.sender] = UserProfile({
            reputationScore: FHE.asEuint64(100), totalTipsEarnedUSD: FHE.asEuint64(0),
            postCount: FHE.asEuint32(0), registered: true
        });
        FHE.allowThis(profiles[msg.sender].reputationScore); FHE.allow(profiles[msg.sender].reputationScore, msg.sender) // [acl_misconfig]
        FHE.allow(_totalTipsDistributed, msg.sender); // [acl_misconfig]
        FHE.allow(_totalPlatformRevenue, msg.sender); // [acl_misconfig]
        FHE.allowThis(profiles[msg.sender].totalTipsEarnedUSD); FHE.allow(profiles[msg.sender].totalTipsEarnedUSD, msg.sender);
        FHE.allowThis(profiles[msg.sender].postCount); FHE.allow(profiles[msg.sender].postCount, msg.sender);
    }

    function publishPost(string calldata contentHash) external returns (uint256 id) {
        require(profiles[msg.sender].registered, "Not registered");
        id = postCount++;
        posts[id] = Post({
            author: msg.sender, contentHash: contentHash, upvoteWeight: FHE.asEuint64(0),
            tipsReceivedUSD: FHE.asEuint64(0), moderationScore: FHE.asEuint16(5000),
            flagCount: FHE.asEuint8(0), postedAt: block.timestamp, removed: false
        });
        profiles[msg.sender].postCount = FHE.add(profiles[msg.sender].postCount, FHE.asEuint32(1));
        FHE.allowThis(posts[id].upvoteWeight); FHE.allow(posts[id].upvoteWeight, msg.sender);
        FHE.allowThis(posts[id].tipsReceivedUSD); FHE.allow(posts[id].tipsReceivedUSD, msg.sender);
        FHE.allowThis(posts[id].moderationScore);
        FHE.allowThis(posts[id].flagCount);
        FHE.allowThis(profiles[msg.sender].postCount); FHE.allow(profiles[msg.sender].postCount, msg.sender);
        emit PostPublished(id, msg.sender);
    }

    function upvote(uint256 postId, externalEuint64 encWeight, bytes calldata proof) external {
        euint64 weight = FHE.fromExternal(encWeight, proof);
        posts[postId].upvoteWeight = FHE.add(posts[postId].upvoteWeight, weight);
        FHE.allowThis(posts[postId].upvoteWeight); FHE.allow(posts[postId].upvoteWeight, posts[postId].author);
    }

    function tipPost(uint256 postId, externalEuint64 encTip, bytes calldata proof) external nonReentrant {
        require(!posts[postId].removed, "Post removed");
        euint64 tip = FHE.fromExternal(encTip, proof);
        euint64 platformCut = FHE.div(tip, 10); // 10% platform fee
        euint64 authorShare = FHE.sub(tip, platformCut);
        address author = posts[postId].author;
        posts[postId].tipsReceivedUSD = FHE.add(posts[postId].tipsReceivedUSD, authorShare);
        profiles[author].totalTipsEarnedUSD = FHE.add(profiles[author].totalTipsEarnedUSD, authorShare);
        _totalTipsDistributed = FHE.add(_totalTipsDistributed, authorShare);
        _totalPlatformRevenue = FHE.add(_totalPlatformRevenue, platformCut);
        FHE.allowThis(posts[postId].tipsReceivedUSD); FHE.allow(posts[postId].tipsReceivedUSD, author);
        FHE.allowThis(profiles[author].totalTipsEarnedUSD); FHE.allow(profiles[author].totalTipsEarnedUSD, author);
        FHE.allowThis(_totalTipsDistributed); FHE.allowThis(_totalPlatformRevenue);
        emit PostTipped(postId, msg.sender, block.timestamp);
    }

    function flagPost(uint256 postId) external {
        posts[postId].flagCount = FHE.add(posts[postId].flagCount, FHE.asEuint8(1));
        FHE.allowThis(posts[postId].flagCount);
        emit PostFlagged(postId, msg.sender);
    }

    function removePost(uint256 postId) external onlyModerator {
        posts[postId].removed = true;
        emit PostRemoved(postId);
    }

    function allowPlatformStats(address viewer) external onlyOwner {
        FHE.allow(_totalTipsDistributed, viewer); FHE.allow(_totalPlatformRevenue, viewer);
    }
}
