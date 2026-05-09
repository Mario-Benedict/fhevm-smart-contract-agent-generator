// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedShipwreckSalvageRights
/// @notice Maritime salvage: encrypted bid values for historical shipwreck exploration rights.
///         Encrypted artifact appraisals, state revenue shares, and finder's percentages.
contract EncryptedShipwreckSalvageRights is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum WreckStatus { Discovered, Surveyed, AuctionOpen, Awarded, Excavating, Completed }

    struct Shipwreck {
        string vesselName;
        string discoveryCoordinates;   // obfuscated location
        uint256 sinkingYear;
        euint64 estimatedArtifactValue; // encrypted estimated value
        euint64 highestBidUSD;         // encrypted current highest bid
        euint32 stateRevShareBps;      // encrypted state's revenue share
        euint32 finderPercBps;         // encrypted finder's percentage
        address highestBidder;
        uint256 auctionEnd;
        WreckStatus status;
    }

    struct SalvageBid {
        uint256 wreckId;
        address company;
        euint64 bidAmountUSD;          // encrypted bid
        euint64 proposedBudgetUSD;     // encrypted excavation budget
        euint32 experienceScore;       // encrypted company experience rating
        bool disqualified;
    }

    mapping(uint256 => Shipwreck) private wrecks;
    mapping(uint256 => SalvageBid) private bids;
    mapping(uint256 => uint256[]) private wreckBids;
    mapping(address => bool) public isMaritimeAuthority;
    mapping(address => bool) public isQualifiedSalvor;

    uint256 public wreckCount;
    uint256 public bidCount;
    euint64 private _totalSalvageValue;

    event WreckRegistered(uint256 indexed id, string vesselName, uint256 sinkYear);
    event BidPlaced(uint256 indexed bidId, uint256 wreckId, address company);
    event RightsAwarded(uint256 indexed wreckId, address winner);

    modifier onlyAuthority() {
        require(isMaritimeAuthority[msg.sender] || msg.sender == owner(), "Not authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSalvageValue = FHE.asEuint64(0);
        FHE.allowThis(_totalSalvageValue);
        isMaritimeAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isMaritimeAuthority[a] = true; }
    function addSalvor(address s) external onlyOwner { isQualifiedSalvor[s] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerWreck(
        string calldata vesselName,
        string calldata coords,
        uint256 sinkYear,
        externalEuint64 encEstValue, bytes calldata vProof,
        externalEuint32 encStateShare, bytes calldata sProof,
        externalEuint32 encFinderPerc, bytes calldata fProof,
        uint256 auctionDays
    ) external onlyAuthority whenNotPaused returns (uint256 id) {
        euint64 estVal = FHE.fromExternal(encEstValue, vProof);
        euint32 stateShare = FHE.fromExternal(encStateShare, sProof);
        euint32 finderPerc = FHE.fromExternal(encFinderPerc, fProof);
        id = wreckCount++;
        wrecks[id].vesselName = vesselName;
        wrecks[id].discoveryCoordinates = coords;
        wrecks[id].sinkingYear = sinkYear;
        wrecks[id].estimatedArtifactValue = estVal;
        wrecks[id].highestBidUSD = FHE.asEuint64(0);
        wrecks[id].stateRevShareBps = stateShare;
        wrecks[id].finderPercBps = finderPerc;
        wrecks[id].highestBidder = address(0);
        wrecks[id].auctionEnd = block.timestamp + auctionDays * 1 days;
        wrecks[id].status = WreckStatus.AuctionOpen;
        _totalSalvageValue = FHE.add(_totalSalvageValue, estVal);
        FHE.allowThis(wrecks[id].estimatedArtifactValue);
        FHE.allowThis(wrecks[id].highestBidUSD);
        FHE.allowThis(wrecks[id].stateRevShareBps);
        FHE.allowThis(wrecks[id].finderPercBps);
        FHE.allowThis(_totalSalvageValue);
        emit WreckRegistered(id, vesselName, sinkYear);
    }

    function placeBid(
        uint256 wreckId,
        externalEuint64 encBid, bytes calldata bProof,
        externalEuint64 encBudget, bytes calldata budProof,
        externalEuint32 encExperience, bytes calldata expProof
    ) external whenNotPaused nonReentrant returns (uint256 bidId) {
        require(isQualifiedSalvor[msg.sender], "Not qualified salvor");
        Shipwreck storage w = wrecks[wreckId];
        require(w.status == WreckStatus.AuctionOpen && block.timestamp < w.auctionEnd, "Auction closed");
        euint64 bid = FHE.fromExternal(encBid, bProof);
        euint64 budget = FHE.fromExternal(encBudget, budProof);
        euint32 exp = FHE.fromExternal(encExperience, expProof);
        bidId = bidCount++;
        bids[bidId] = SalvageBid({
            wreckId: wreckId, company: msg.sender,
            bidAmountUSD: bid, proposedBudgetUSD: budget,
            experienceScore: exp, disqualified: false
        });
        // Update highest bid
        ebool isHigher = FHE.gt(bid, w.highestBidUSD);
        w.highestBidUSD = FHE.select(isHigher, bid, w.highestBidUSD);
        w.highestBidder = FHE.isInitialized(isHigher) ? msg.sender : w.highestBidder;
        wreckBids[wreckId].push(bidId);
        FHE.allowThis(bids[bidId].bidAmountUSD);
        FHE.allow(bids[bidId].bidAmountUSD, msg.sender);
        FHE.allowThis(bids[bidId].proposedBudgetUSD);
        FHE.allow(bids[bidId].proposedBudgetUSD, msg.sender);
        FHE.allowThis(bids[bidId].experienceScore);
        FHE.allowThis(w.highestBidUSD);
        emit BidPlaced(bidId, wreckId, msg.sender);
    }

    function awardRights(uint256 wreckId) external onlyAuthority nonReentrant {
        Shipwreck storage w = wrecks[wreckId];
        require(w.status == WreckStatus.AuctionOpen && block.timestamp >= w.auctionEnd, "Not ended");
        w.status = WreckStatus.Awarded;
        FHE.allow(w.highestBidUSD, w.highestBidder);
        FHE.allow(w.stateRevShareBps, w.highestBidder);
        FHE.allow(w.finderPercBps, w.highestBidder);
        emit RightsAwarded(wreckId, w.highestBidder);
    }

    function allowSalvageStats(address viewer) external onlyOwner {
        FHE.allow(_totalSalvageValue, viewer);
    }
}
