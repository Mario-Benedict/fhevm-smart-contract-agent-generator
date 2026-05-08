// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionMediaBroadcastRights
/// @notice Media broadcast rights auction where broadcasters bid CPM rates and
///         viewership commitment guarantees. Encrypted audience reach scores
///         ensure winner meets minimum distribution requirements.
contract AuctionMediaBroadcastRights is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct ContentPackage {
        string contentName;
        string rightsTerritory;
        euint64 minimumCPMBid;        // encrypted min cost per mille
        euint32 minViewershipMillions; // encrypted min guaranteed viewership
        uint256 auctionEnd;
        bool finalized;
        address winner;
        euint64 winningCPM;
        euint32 winningViewership;
    }

    struct BroadcasterBid {
        euint64 offeredCPM;
        euint32 viewershipGuarantee; // in millions
        euint8 reachScore;           // encrypted geographic reach score
        bool placed;
    }

    mapping(uint256 => ContentPackage) private packages;
    uint256 public packageCount;
    mapping(uint256 => mapping(address => BroadcasterBid)) private bids;
    mapping(uint256 => address[]) private broadcasters;
    mapping(address => bool) public isLicensedBroadcaster;

    event PackageListed(uint256 indexed id, string contentName);
    event BidSubmitted(uint256 indexed id, address broadcaster);
    event RightsAwarded(uint256 indexed id, address winner);

    constructor() Ownable(msg.sender) {}

    function licenseBroadcaster(address b) external onlyOwner { isLicensedBroadcaster[b] = true; }

    function listPackage(
        string calldata contentName, string calldata territory,
        externalEuint64 encMinCPM, bytes calldata cProof,
        externalEuint32 encMinView, bytes calldata vProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = packageCount++;
        ContentPackage storage p = packages[id];
        p.contentName = contentName;
        p.rightsTerritory = territory;
        p.minimumCPMBid = FHE.fromExternal(encMinCPM, cProof);
        p.minViewershipMillions = FHE.fromExternal(encMinView, vProof);
        p.auctionEnd = block.timestamp + auctionDays * 1 days;
        p.winningCPM = FHE.asEuint64(0);
        p.winningViewership = FHE.asEuint32(0);
        FHE.allowThis(p.minimumCPMBid);
        FHE.allowThis(p.minViewershipMillions);
        FHE.allowThis(p.winningCPM);
        FHE.allowThis(p.winningViewership);
        emit PackageListed(id, contentName);
    }

    function submitBid(
        uint256 pkgId,
        externalEuint64 encCPM, bytes calldata cProof,
        externalEuint32 encViewership, bytes calldata vProof,
        externalEuint8 encReach, bytes calldata rProof
    ) external nonReentrant {
        require(isLicensedBroadcaster[msg.sender], "Not licensed");
        ContentPackage storage p = packages[pkgId];
        require(block.timestamp < p.auctionEnd, "Closed");
        require(!bids[pkgId][msg.sender].placed, "Already bid");
        bids[pkgId][msg.sender] = BroadcasterBid({
            offeredCPM: FHE.fromExternal(encCPM, cProof),
            viewershipGuarantee: FHE.fromExternal(encViewership, vProof),
            reachScore: FHE.fromExternal(encReach, rProof),
            placed: true
        });
        FHE.allowThis(bids[pkgId][msg.sender].offeredCPM);
        FHE.allowThis(bids[pkgId][msg.sender].viewershipGuarantee);
        FHE.allowThis(bids[pkgId][msg.sender].reachScore);
        broadcasters[pkgId].push(msg.sender);
        emit BidSubmitted(pkgId, msg.sender);
    }

    function awardRights(uint256 pkgId) external onlyOwner nonReentrant {
        ContentPackage storage p = packages[pkgId];
        require(block.timestamp >= p.auctionEnd && !p.finalized, "Cannot award");
        p.finalized = true;
        euint64 bestCPM = FHE.asEuint64(0);
        address bestBidder = address(0);
        address[] storage bs = broadcasters[pkgId];
        for (uint256 i = 0; i < bs.length; i++) {
            BroadcasterBid storage b = bids[pkgId][bs[i]];
            ebool cpmOk = FHE.ge(b.offeredCPM, p.minimumCPMBid);
            ebool viewOk = FHE.ge(b.viewershipGuarantee, p.minViewershipMillions);
            ebool valid = FHE.and(cpmOk, viewOk);
            ebool isBest = FHE.gt(b.offeredCPM, bestCPM);
            ebool winner = FHE.and(valid, isBest);
            bestCPM = FHE.select(winner, b.offeredCPM, bestCPM);
            if (FHE.isInitialized(winner)) {
                bestBidder = bs[i];
                p.winningViewership = b.viewershipGuarantee;
            }
        }
        p.winner = bestBidder;
        p.winningCPM = bestCPM;
        FHE.allowThis(p.winningCPM);
        FHE.allowThis(p.winningViewership);
        if (bestBidder != address(0)) {
            FHE.allow(p.winningCPM, bestBidder);
            FHE.allow(p.winningViewership, bestBidder);
        }
        emit RightsAwarded(pkgId, bestBidder);
    }
}
