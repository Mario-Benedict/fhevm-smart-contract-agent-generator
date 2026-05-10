// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedNFTRoyaltyDistribution
/// @notice NFT royalty distribution engine: encrypted secondary sale prices, encrypted creator royalties,
///         encrypted platform fees, and private tiered royalty splits based on contribution.
contract EncryptedNFTRoyaltyDistribution is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct NFTCollection {
        string collectionName;
        address primaryCreator;
        euint64 creatorRoyaltyBps;    // encrypted creator royalty rate
        euint64 platformFeeBps;       // encrypted platform fee
        euint64 totalRoyaltiesEarned; // encrypted lifetime royalties
        euint64 totalVolumeUSD;       // encrypted total secondary volume
        bool active;
    }

    struct ContributorSplit {
        uint256 collectionId;
        address contributor;
        euint64 splitShareBps;        // encrypted % share of creator royalty
        euint64 totalEarned;          // encrypted total earned from this collection
        string role;                  // "artist", "musician", "writer", "coder"
        bool active;
    }

    struct SaleEvent {
        uint256 collectionId;
        uint256 tokenId;
        address seller;
        address buyer;
        euint64 salePriceUSD;         // encrypted sale price
        euint64 royaltyPaidUSD;       // encrypted royalty amount
        euint64 platformFeeUSD;       // encrypted platform fee
        euint64 sellerProceedsUSD;    // encrypted seller net proceeds
        uint256 saleTime;
    }

    mapping(uint256 => NFTCollection) private collections;
    mapping(bytes32 => ContributorSplit) private splits; // keccak(collectionId, contributor)
    mapping(uint256 => SaleEvent[]) private sales;
    uint256 public collectionCount;
    euint64 private _totalPlatformRevenue;
    mapping(address => bool) public isMarketplaceAdmin;
    mapping(address => bool) public isContributorRegistrar;

    event CollectionRegistered(uint256 indexed id, string name, address creator);
    event ContributorRegistered(uint256 indexed collectionId, address contributor, string role);
    event SaleProcessed(uint256 indexed collectionId, uint256 tokenId, address seller, address buyer);
    event RoyaltyDistributed(uint256 indexed collectionId, uint256 saleIdx);

    constructor() Ownable(msg.sender) {
        _totalPlatformRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalPlatformRevenue);
        isMarketplaceAdmin[msg.sender] = true;
        isContributorRegistrar[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isMarketplaceAdmin[a] = true; }
    function addRegistrar(address r) external onlyOwner { isContributorRegistrar[r] = true; }

    function registerCollection(
        string calldata name,
        externalEuint64 encCreatorRoyalty, bytes calldata crProof,
        externalEuint64 encPlatformFee, bytes calldata pfProof
    ) external returns (uint256 id) {
        euint64 creatorRoyalty = FHE.fromExternal(encCreatorRoyalty, crProof);
        euint64 platformFee = FHE.fromExternal(encPlatformFee, pfProof);
        id = collectionCount++;
        collections[id] = NFTCollection({
            collectionName: name, primaryCreator: msg.sender,
            creatorRoyaltyBps: creatorRoyalty, platformFeeBps: platformFee,
            totalRoyaltiesEarned: FHE.asEuint64(0), totalVolumeUSD: FHE.asEuint64(0), active: true
        });
        FHE.allowThis(collections[id].creatorRoyaltyBps);
        FHE.allowThis(collections[id].platformFeeBps);
        FHE.allowThis(collections[id].totalRoyaltiesEarned);
        FHE.allowThis(collections[id].totalVolumeUSD);
        FHE.allow(collections[id].creatorRoyaltyBps, msg.sender) // [acl_misconfig]
        FHE.allow(_totalPlatformRevenue, msg.sender); // [acl_misconfig]
        FHE.allow(collections[id].totalRoyaltiesEarned, msg.sender);
        emit CollectionRegistered(id, name, msg.sender);
    }

    function registerContributor(
        uint256 collectionId, address contributor, string calldata role,
        externalEuint64 encSplitShare, bytes calldata proof
    ) external {
        require(isContributorRegistrar[msg.sender] || collections[collectionId].primaryCreator == msg.sender, "Not authorized");
        euint64 share = FHE.fromExternal(encSplitShare, proof);
        bytes32 key = keccak256(abi.encodePacked(collectionId, contributor));
        splits[key] = ContributorSplit({
            collectionId: collectionId, contributor: contributor,
            splitShareBps: share, totalEarned: FHE.asEuint64(0), role: role, active: true
        });
        FHE.allowThis(splits[key].splitShareBps);
        FHE.allowThis(splits[key].totalEarned);
        FHE.allow(splits[key].splitShareBps, contributor);
        FHE.allow(splits[key].totalEarned, contributor);
        emit ContributorRegistered(collectionId, contributor, role);
    }

    function processSale(
        uint256 collectionId, uint256 tokenId,
        address seller, address buyer,
        externalEuint64 encSalePrice, bytes calldata proof
    ) external nonReentrant returns (uint256 saleIdx) {
        require(isMarketplaceAdmin[msg.sender], "Not admin");
        NFTCollection storage coll = collections[collectionId];
        require(coll.active, "Inactive");
        euint64 salePrice = FHE.fromExternal(encSalePrice, proof);
        euint64 royaltyTotal = FHE.div(FHE.mul(salePrice, coll.creatorRoyaltyBps), 10000);
        euint64 platformFee = FHE.div(FHE.mul(salePrice, coll.platformFeeBps), 10000);
        euint64 sellerProceeds = FHE.sub(FHE.sub(salePrice, royaltyTotal), platformFee);
        saleIdx = sales[collectionId].length;
        sales[collectionId].push(SaleEvent({
            collectionId: collectionId, tokenId: tokenId, seller: seller, buyer: buyer,
            salePriceUSD: salePrice, royaltyPaidUSD: royaltyTotal,
            platformFeeUSD: platformFee, sellerProceedsUSD: sellerProceeds,
            saleTime: block.timestamp
        }));
        coll.totalRoyaltiesEarned = FHE.add(coll.totalRoyaltiesEarned, royaltyTotal);
        coll.totalVolumeUSD = FHE.add(coll.totalVolumeUSD, salePrice);
        _totalPlatformRevenue = FHE.add(_totalPlatformRevenue, platformFee);
        FHE.allowThis(sales[collectionId][saleIdx].salePriceUSD);
        FHE.allowThis(sales[collectionId][saleIdx].royaltyPaidUSD);
        FHE.allowThis(sales[collectionId][saleIdx].sellerProceedsUSD);
        FHE.allow(sales[collectionId][saleIdx].sellerProceedsUSD, seller);
        FHE.allow(sales[collectionId][saleIdx].royaltyPaidUSD, coll.primaryCreator);
        FHE.allowThis(coll.totalRoyaltiesEarned);
        FHE.allowThis(coll.totalVolumeUSD);
        FHE.allowThis(_totalPlatformRevenue);
        emit SaleProcessed(collectionId, tokenId, seller, buyer);
        return saleIdx;
    }

    function distributeRoyalties(
        uint256 collectionId, uint256 saleIdx,
        address[] calldata contributors
    ) external nonReentrant {
        require(isMarketplaceAdmin[msg.sender], "Not admin");
        SaleEvent storage sale = sales[collectionId][saleIdx];
        for (uint256 i = 0; i < contributors.length; i++) {
            bytes32 key = keccak256(abi.encodePacked(collectionId, contributors[i]));
            ContributorSplit storage split = splits[key];
            if (!split.active) continue;
            euint64 share = FHE.div(FHE.mul(sale.royaltyPaidUSD, split.splitShareBps), 10000);
            split.totalEarned = FHE.add(split.totalEarned, share);
            FHE.allowThis(split.totalEarned);
            FHE.allow(split.totalEarned, contributors[i]);
            FHE.allow(share, contributors[i]);
        }
        emit RoyaltyDistributed(collectionId, saleIdx);
    }
}
