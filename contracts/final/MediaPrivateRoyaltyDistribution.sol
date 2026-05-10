// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MediaPrivateRoyaltyDistribution
/// @notice Music/media royalty distribution where streaming counts and
///         per-stream rates are encrypted. Artists receive confidential
///         royalty breakdowns without exposing streaming analytics to competitors.
contract MediaPrivateRoyaltyDistribution is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct ContentAsset {
        string title;
        string isrc;         // International Standard Recording Code
        address[] rightholders;
        euint16[] splitsBps;  // encrypted splits (sum = 10000)
        euint32 totalStreams;  // encrypted
        euint64 totalRoyalties;
        bool registered;
    }

    struct RoyaltyPeriod {
        uint256 periodStart;
        uint256 periodEnd;
        euint64 totalRevenue;
        bool distributed;
    }

    mapping(uint256 => ContentAsset) private assets;
    uint256 public assetCount;
    mapping(uint256 => RoyaltyPeriod) private periods;
    uint256 public periodCount;
    mapping(address => euint64) private artistBalance;
    euint64 private _platformRoyaltyBps;

    event AssetRegistered(uint256 indexed id, string title);
    event StreamsReported(uint256 indexed assetId, uint256 periodId);
    event RoyaltiesDistributed(uint256 indexed periodId);

    constructor(externalEuint64 encPlatformRoyalty, bytes memory proof) Ownable(msg.sender) {
        _platformRoyaltyBps = FHE.fromExternal(encPlatformRoyalty, proof);
        FHE.allowThis(_platformRoyaltyBps);
    }

    function registerAsset(
        string calldata title, string calldata isrc,
        address[] calldata rightholders,
        externalEuint16[] calldata encSplits, bytes[] calldata proofs
    ) external onlyOwner returns (uint256 id) {
        require(rightholders.length == encSplits.length, "Mismatch");
        id = assetCount++;
        assets[id].title = title;
        assets[id].isrc = isrc;
        assets[id].rightholders = rightholders;
        assets[id].totalStreams = FHE.asEuint32(0);
        assets[id].totalRoyalties = FHE.asEuint64(0);
        assets[id].registered = true;
        FHE.allowThis(assets[id].totalStreams);
        FHE.allowThis(assets[id].totalRoyalties);
        for (uint256 i = 0; i < rightholders.length; i++) {
            euint16 split = FHE.fromExternal(encSplits[i], proofs[i]);
            assets[id].splitsBps.push(split);
            FHE.allowThis(assets[id].splitsBps[i]);
            FHE.allow(assets[id].splitsBps[i], rightholders[i]);
        }
        emit AssetRegistered(id, title);
    }

    function createPeriod(uint256 durationDays) external onlyOwner returns (uint256 id) {
        id = periodCount++;
        periods[id].periodStart = block.timestamp;
        periods[id].periodEnd = block.timestamp + durationDays * 1 days;
        periods[id].totalRevenue = FHE.asEuint64(0);
        FHE.allowThis(periods[id].totalRevenue);
    }

    function reportStreams(
        uint256 assetId, uint256 periodId,
        externalEuint32 encStreams, bytes calldata sProof,
        externalEuint64 encRevenue, bytes calldata rProof
    ) external onlyOwner {
        euint32 streams = FHE.fromExternal(encStreams, sProof);
        euint64 revenue = FHE.fromExternal(encRevenue, rProof);
        assets[assetId].totalStreams = FHE.add(assets[assetId].totalStreams, streams);
        periods[periodId].totalRevenue = FHE.add(periods[periodId].totalRevenue, revenue);
        FHE.allowThis(assets[assetId].totalStreams);
        FHE.allowThis(periods[periodId].totalRevenue);
        emit StreamsReported(assetId, periodId);
    }

    function distributeRoyalties(uint256 periodId, uint256[] calldata assetIds) external onlyOwner nonReentrant {
        RoyaltyPeriod storage p = periods[periodId];
        require(!p.distributed && block.timestamp >= p.periodEnd, "Cannot distribute");
        p.distributed = true;
        euint64 platformCut = FHE.div(FHE.mul(p.totalRevenue, _platformRoyaltyBps), 10000); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 artistPool = FHE.sub(p.totalRevenue, platformCut);
        for (uint256 i = 0; i < assetIds.length; i++) {
            ContentAsset storage asset = assets[assetIds[i]];
            euint64 assetShare = FHE.div(artistPool, uint64(assetIds.length));
            for (uint256 j = 0; j < asset.rightholders.length; j++) {
                euint64 holderShare = FHE.div(assetShare, uint64(asset.rightholders.length));
                artistBalance[asset.rightholders[j]] = FHE.add(artistBalance[asset.rightholders[j]], holderShare);
                FHE.allowThis(artistBalance[asset.rightholders[j]]);
                FHE.allow(artistBalance[asset.rightholders[j]], asset.rightholders[j]);
            }
        }
        FHE.allow(platformCut, owner());
        emit RoyaltiesDistributed(periodId);
    }

    function withdrawRoyalties() external nonReentrant {
        euint64 balance = artistBalance[msg.sender];
        artistBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allow(balance, msg.sender);
        FHE.allowThis(artistBalance[msg.sender]);
    }

    function allowArtistData(address viewer) external {
        FHE.allow(artistBalance[msg.sender], viewer);
    }
}
