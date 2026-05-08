// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateRoyaltyDistributor - Confidential music royalty collection and split distribution
contract PrivateRoyaltyDistributor is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Track {
        string isrc;           // International Standard Recording Code
        string title;
        euint64 totalRoyalties;
        euint64 distributedRoyalties;
        uint8 rightsholderCount;
        bool active;
    }

    struct RightsSplit {
        address rightsholder;
        euint8 sharePercent;   // must sum to 100 across track
        euint64 pendingPayout;
        euint64 totalReceived;
    }

    mapping(uint256 => Track) public tracks;
    mapping(uint256 => mapping(uint8 => RightsSplit)) private splits;
    mapping(address => euint64) public creatorEarnings;
    uint256 public trackCount;

    event TrackRegistered(uint256 indexed trackId, string isrc);
    event RightsholderAdded(uint256 indexed trackId, address indexed rightsholder);
    event RoyaltiesDeposited(uint256 indexed trackId);
    event RoyaltiesClaimed(uint256 indexed trackId, address indexed rightsholder);

    constructor() Ownable(msg.sender) {}

    function registerTrack(string calldata isrc, string calldata title)
        external returns (uint256 trackId)
    {
        trackId = trackCount++;
        Track storage t = tracks[trackId];
        t.isrc  = isrc;
        t.title = title;
        t.totalRoyalties      = FHE.asEuint64(0);
        t.distributedRoyalties = FHE.asEuint64(0);
        t.active = true;
        FHE.allowThis(t.totalRoyalties);
        FHE.allowThis(t.distributedRoyalties);
        emit TrackRegistered(trackId, isrc);
    }

    function addRightsholder(
        uint256 trackId,
        address rightsholder,
        externalEuint8 calldata encShare,
        bytes calldata inputProof
    ) external onlyOwner {
        Track storage t = tracks[trackId];
        uint8 idx = t.rightsholderCount++;
        RightsSplit storage s = splits[trackId][idx];
        s.rightsholder  = rightsholder;
        s.sharePercent  = FHE.fromExternal(encShare, inputProof);
        s.pendingPayout = FHE.asEuint64(0);
        s.totalReceived = FHE.asEuint64(0);
        FHE.allowThis(s.sharePercent); FHE.allowThis(s.pendingPayout); FHE.allowThis(s.totalReceived);
        FHE.allow(s.sharePercent, rightsholder);
        FHE.allow(s.pendingPayout, rightsholder);
        emit RightsholderAdded(trackId, rightsholder);
    }

    function depositRoyalties(uint256 trackId, externalEuint64 calldata encAmount, bytes calldata inputProof)
        external onlyOwner
    {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        Track storage t = tracks[trackId];
        t.totalRoyalties = FHE.add(t.totalRoyalties, amount);
        FHE.allowThis(t.totalRoyalties);
        for (uint8 i = 0; i < t.rightsholderCount; i++) {
            RightsSplit storage s = splits[trackId][i];
            euint64 share = FHE.div(
                FHE.mul(amount, FHE.asEuint64(s.sharePercent.unwrap())),
                FHE.asEuint64(100)
            );
            s.pendingPayout = FHE.add(s.pendingPayout, share);
            FHE.allowThis(s.pendingPayout);
            FHE.allow(s.pendingPayout, s.rightsholder);
        }
        emit RoyaltiesDeposited(trackId);
    }

    function claimRoyalties(uint256 trackId, uint8 splitIndex) external nonReentrant {
        RightsSplit storage s = splits[trackId][splitIndex];
        require(s.rightsholder == msg.sender, "Not rightsholder");
        euint64 payout = s.pendingPayout;
        s.pendingPayout = FHE.asEuint64(0);
        s.totalReceived = FHE.add(s.totalReceived, payout);
        tracks[trackId].distributedRoyalties = FHE.add(tracks[trackId].distributedRoyalties, payout);
        FHE.allowThis(s.pendingPayout); FHE.allowThis(s.totalReceived);
        FHE.allowThis(tracks[trackId].distributedRoyalties);
        FHE.allow(s.totalReceived, msg.sender);
        FHE.allowTransient(payout, msg.sender);
        emit RoyaltiesClaimed(trackId, msg.sender);
    }
}
