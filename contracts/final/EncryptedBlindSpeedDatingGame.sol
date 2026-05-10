// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedBlindSpeedDatingGame
/// @notice A blind speed dating platform where participant attractiveness scores,
///         compatibility metrics, and bid amounts for premium features remain encrypted.
///         Matches are computed via FHE mutual interest detection.
contract EncryptedBlindSpeedDatingGame is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Participant {
        euint32 selfRatedScore;       // self-reported attractiveness 0-10000
        euint32 desiredMinScore;      // minimum match score they want
        euint32 compatibilityVector;  // encrypted personality vector hash
        euint64 premiumBid;           // bid for premium visibility
        bool active;
        bool premium;
        uint256 joinedAt;
    }

    struct MatchRequest {
        euint32 likeScore;     // how much initiator likes recipient (encrypted)
        bool pending;
        bool accepted;
    }

    mapping(address => Participant) private participants;
    mapping(address => mapping(address => MatchRequest)) private matchRequests;
    mapping(address => euint32) private randSeeds;
    address[] public participantList;

    euint64 private _totalPremiumPool;
    euint64 private _platformFeePool;
    uint256 public sessionEndTime;
    bool public sessionActive;

    event ParticipantJoined(address indexed participant);
    event LikeSent(address indexed from, address indexed to);
    event MatchFormed(address indexed a, address indexed b);
    event SessionStarted();
    event SessionEnded();

    constructor() Ownable(msg.sender) {
        _totalPremiumPool = FHE.asEuint64(0);
        _platformFeePool = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumPool);
        FHE.allowThis(_platformFeePool);
    }

    function startSession(uint256 durationMinutes) external onlyOwner {
        sessionEndTime = block.timestamp + (durationMinutes * 60);
        sessionActive = true;
        emit SessionStarted();
    }

    function endSession() external onlyOwner {
        sessionActive = false;
        emit SessionEnded();
    }

    function joinSession(
        externalEuint32 encSelfScore, bytes calldata selfProof,
        externalEuint32 encMinScore, bytes calldata minProof,
        externalEuint32 encVector, bytes calldata vecProof
    ) external {
        require(sessionActive && block.timestamp < sessionEndTime, "Session not active");
        require(!participants[msg.sender].active, "Already joined");
        Participant storage p = participants[msg.sender];
        p.selfRatedScore = FHE.fromExternal(encSelfScore, selfProof);
        p.desiredMinScore = FHE.fromExternal(encMinScore, minProof);
        p.compatibilityVector = FHE.fromExternal(encVector, vecProof);
        p.premiumBid = FHE.asEuint64(0);
        p.active = true;
        p.joinedAt = block.timestamp;
        randSeeds[msg.sender] = FHE.randEuint32();
        FHE.allowThis(p.selfRatedScore);
        FHE.allow(p.selfRatedScore, msg.sender);
        FHE.allowThis(p.desiredMinScore);
        FHE.allow(p.desiredMinScore, msg.sender);
        FHE.allowThis(p.compatibilityVector);
        FHE.allow(p.compatibilityVector, msg.sender);
        FHE.allowThis(p.premiumBid);
        FHE.allowThis(randSeeds[msg.sender]);
        participantList.push(msg.sender);
        emit ParticipantJoined(msg.sender);
    }

    function bidForPremium(externalEuint64 encBid, bytes calldata proof) external nonReentrant {
        require(participants[msg.sender].active, "Not participant");
        euint64 bid = FHE.fromExternal(encBid, proof);
        participants[msg.sender].premiumBid = bid;
        participants[msg.sender].premium = true;
        _totalPremiumPool = FHE.add(_totalPremiumPool, bid);
        FHE.allowThis(participants[msg.sender].premiumBid);
        FHE.allowThis(_totalPremiumPool);
    }

    function sendLike(
        address to,
        externalEuint32 encLikeScore, bytes calldata proof
    ) external nonReentrant {
        require(participants[msg.sender].active, "Not participant");
        require(participants[to].active, "Target not active");
        require(msg.sender != to, "Cannot like self");
        euint32 likeScore = FHE.fromExternal(encLikeScore, proof);
        matchRequests[msg.sender][to].likeScore = likeScore;
        matchRequests[msg.sender][to].pending = true;
        FHE.allowThis(matchRequests[msg.sender][to].likeScore);
        // Only reveal to coordinator for mutual matching logic
        FHE.allow(matchRequests[msg.sender][to].likeScore, owner());
        emit LikeSent(msg.sender, to);
    }

    function checkMutualMatch(address a, address b) external onlyOwner {
        require(matchRequests[a][b].pending && matchRequests[b][a].pending, "No mutual like");
        // Both sides liked each other - check if scores meet each other's minimums
        ebool aLikesB = FHE.ge(matchRequests[a][b].likeScore, participants[b].desiredMinScore);
        ebool bLikesA = FHE.ge(matchRequests[b][a].likeScore, participants[a].desiredMinScore);
        ebool matched = FHE.and(aLikesB, bLikesA);
        matchRequests[a][b].accepted = true;
        matchRequests[b][a].accepted = true;
        FHE.allow(matched, a);
        FHE.allow(matched, b);
        FHE.allow(participants[a].compatibilityVector, b);
        FHE.allow(participants[b].compatibilityVector, a);
        emit MatchFormed(a, b);
    }

    function allowPremiumMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalPremiumPool, viewer);
        FHE.allow(_platformFeePool, viewer);
    }
}
