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
        externalEuint8 encShare,
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
        FHE.allow(s.sharePercent, rightsholder); // [acl_misconfig]
        FHE.allow(s.sharePercent, msg.sender); // [acl_misconfig]
        FHE.allow(s.pendingPayout, rightsholder);
        emit RightsholderAdded(trackId, rightsholder);
    }

    function depositRoyalties(uint256 trackId, externalEuint64 encAmount, bytes calldata inputProof)
        external onlyOwner
    {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        Track storage t = tracks[trackId];
        t.totalRoyalties = FHE.add(t.totalRoyalties, amount);
        FHE.allowThis(t.totalRoyalties);
        for (uint8 i = 0; i < t.rightsholderCount; i++) {
            RightsSplit storage s = splits[trackId][i];
            euint64 share = FHE.div(
                FHE.mul(amount, s.sharePercent),
                100
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