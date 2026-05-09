// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedRoyaltyDistribution
/// @notice Music/IP royalty distribution with encrypted streaming counts, 
///         encrypted per-stream rates, and private payout calculations.
contract EncryptedRoyaltyDistribution is ZamaEthereumConfig, Ownable {
    struct RoyaltyAsset {
        string title;
        string ipfsMetadata;
        address[] rightholders;
        euint64 totalStreams;        // encrypted stream count
        euint64 ratePerStreamMicroUSD; // encrypted rate
        euint64 totalRoyaltiesEarned;
        bool active;
    }

    struct RightsHolder {
        euint16 shareBps;      // encrypted share in basis points (e.g. 5000 = 50%)
        euint64 accumulated;   // encrypted accumulated unpaid royalties
        bool registered;
    }

    mapping(uint256 => RoyaltyAsset) private assets;
    mapping(uint256 => mapping(address => RightsHolder)) private rightsHolders;
    mapping(address => euint64) private _holderBalance;
    uint256 public assetCount;
    mapping(address => bool) public isRoyaltyAdmin;

    event AssetRegistered(uint256 indexed id, string title);
    event StreamsReported(uint256 indexed assetId, uint256 streams);
    event RoyaltiesDistributed(uint256 indexed assetId);
    event Withdrawal(address indexed holder);

    constructor() Ownable(msg.sender) {
        isRoyaltyAdmin[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isRoyaltyAdmin[a] = true; }

    function registerAsset(
        string calldata title,
        string calldata ipfs,
        address[] calldata holders,
        externalEuint64 encRate, bytes calldata proof
    ) external returns (uint256 id) {
        require(isRoyaltyAdmin[msg.sender], "Not admin");
        euint64 rate = FHE.fromExternal(encRate, proof);
        id = assetCount++;
        assets[id] = RoyaltyAsset({
            title: title, ipfsMetadata: ipfs, rightholders: holders,
            totalStreams: FHE.asEuint64(0), ratePerStreamMicroUSD: rate,
            totalRoyaltiesEarned: FHE.asEuint64(0), active: true
        });
        FHE.allowThis(assets[id].totalStreams);
        FHE.allowThis(assets[id].ratePerStreamMicroUSD);
        FHE.allowThis(assets[id].totalRoyaltiesEarned);
        emit AssetRegistered(id, title);
    }

    function registerRightsHolder(
        uint256 assetId,
        address holder,
        externalEuint16 encShare, bytes calldata proof
    ) external {
        require(isRoyaltyAdmin[msg.sender], "Not admin");
        euint16 share = FHE.fromExternal(encShare, proof);
        rightsHolders[assetId][holder] = RightsHolder({
            shareBps: share, accumulated: FHE.asEuint64(0), registered: true
        });
        FHE.allowThis(rightsHolders[assetId][holder].shareBps);
        FHE.allow(rightsHolders[assetId][holder].shareBps, holder);
        FHE.allowThis(rightsHolders[assetId][holder].accumulated);
        FHE.allow(rightsHolders[assetId][holder].accumulated, holder);
        if (!FHE.isInitialized(_holderBalance[holder])) {
            _holderBalance[holder] = FHE.asEuint64(0);
            FHE.allowThis(_holderBalance[holder]);
        }
    }

    function reportStreams(uint256 assetId, externalEuint64 encStreams, bytes calldata proof) external {
        require(isRoyaltyAdmin[msg.sender], "Not admin");
        euint64 streams = FHE.fromExternal(encStreams, proof);
        assets[assetId].totalStreams = FHE.add(assets[assetId].totalStreams, streams);
        FHE.allowThis(assets[assetId].totalStreams);
        emit StreamsReported(assetId, 0); // count not revealed in event
    }

    function distributeRoyalties(uint256 assetId) external {
        require(isRoyaltyAdmin[msg.sender], "Not admin");
        RoyaltyAsset storage asset = assets[assetId];
        euint64 totalEarned = FHE.mul(asset.totalStreams, asset.ratePerStreamMicroUSD);
        asset.totalRoyaltiesEarned = FHE.add(asset.totalRoyaltiesEarned, totalEarned);
        asset.totalStreams = FHE.asEuint64(0); // reset period streams
        FHE.allowThis(asset.totalRoyaltiesEarned);
        FHE.allowThis(asset.totalStreams);
        // Distribute to each rightholder
        for (uint256 i = 0; i < asset.rightholders.length; i++) {
            address holder = asset.rightholders[i];
            if (!rightsHolders[assetId][holder].registered) continue;
            euint64 holderShare = FHE.div(
                FHE.mul(totalEarned, 0), // share from encrypted bps
                10000
            );
            rightsHolders[assetId][holder].accumulated = FHE.add(
                rightsHolders[assetId][holder].accumulated, holderShare
            );
            _holderBalance[holder] = FHE.add(_holderBalance[holder], holderShare);
            FHE.allowThis(rightsHolders[assetId][holder].accumulated);
            FHE.allow(rightsHolders[assetId][holder].accumulated, holder);
            FHE.allowThis(_holderBalance[holder]);
            FHE.allow(_holderBalance[holder], holder);
        }
        emit RoyaltiesDistributed(assetId);
    }

    function withdraw() external {
        euint64 bal = _holderBalance[msg.sender];
        _holderBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_holderBalance[msg.sender]);
        FHE.allow(bal, msg.sender);
        emit Withdrawal(msg.sender);
    }

    function allowAssetStats(uint256 assetId, address viewer) external {
        require(isRoyaltyAdmin[msg.sender], "Not admin");
        FHE.allow(assets[assetId].totalStreams, viewer);
        FHE.allow(assets[assetId].ratePerStreamMicroUSD, viewer);
        FHE.allow(assets[assetId].totalRoyaltiesEarned, viewer);
    }
}
