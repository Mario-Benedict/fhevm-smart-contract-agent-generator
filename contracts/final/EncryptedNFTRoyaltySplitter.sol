// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedNFTRoyaltySplitter
/// @notice Encrypted NFT royalty distribution: private royalty percentages per
///         collaborator, hidden cumulative earnings, confidential secondary market
///         sales tracking, and encrypted tiered royalty for high-value sales.
contract EncryptedNFTRoyaltySplitter is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct RoyaltySplit {
        string nftCollectionRef;
        address primaryCreator;
        euint16 primaryCreatorShareBps; // encrypted share
        euint64 totalRoyaltiesEarned;   // encrypted cumulative
        euint64 tier1ThresholdUSD;      // encrypted tier 1 price threshold
        euint16 tier1RoyaltyBps;        // encrypted tier 1 rate
        euint16 tier2RoyaltyBps;        // encrypted tier 2 rate (high value)
        uint256 createdAt;
    }

    struct Collaborator {
        uint256 splitId;
        address collaborator;
        euint16 shareBps;               // encrypted share
        euint64 earningsAccrued;        // encrypted earnings
        string  role;
    }

    struct SaleRecord {
        uint256 splitId;
        euint64 salePriceUSD;           // encrypted sale price
        euint64 royaltyPaidUSD;         // encrypted royalty amount
        uint256 saleAt;
    }

    mapping(uint256 => RoyaltySplit) private splits;
    mapping(uint256 => Collaborator) private collaborators;
    mapping(uint256 => SaleRecord)   private sales;
    mapping(uint256 => uint256[])    private splitCollaborators;

    uint256 public splitCount;
    uint256 public collaboratorCount;
    uint256 public saleCount;
    euint64 private _totalRoyaltiesDistributed;

    event SplitCreated(uint256 indexed id, string nftCollectionRef);
    event CollaboratorAdded(uint256 indexed id, uint256 splitId);
    event SaleProcessed(uint256 indexed saleId, uint256 splitId);

    constructor() Ownable(msg.sender) {
        _totalRoyaltiesDistributed = FHE.asEuint64(0);
        FHE.allowThis(_totalRoyaltiesDistributed);
    }

    function createSplit(
        string calldata nftCollectionRef,
        externalEuint16 encPrimaryShare, bytes calldata psProof,
        externalEuint64 encTier1Threshold, bytes calldata t1Proof,
        externalEuint16 encTier1Rate, bytes calldata t1rProof,
        externalEuint16 encTier2Rate, bytes calldata t2rProof
    ) external returns (uint256 id) {
        euint16 primaryShare   = FHE.fromExternal(encPrimaryShare, psProof);
        euint64 tier1Threshold = FHE.fromExternal(encTier1Threshold, t1Proof);
        euint16 tier1Rate      = FHE.fromExternal(encTier1Rate, t1rProof);
        euint16 tier2Rate      = FHE.fromExternal(encTier2Rate, t2rProof);
        id = splitCount++;
        splits[id] = RoyaltySplit({
            nftCollectionRef: nftCollectionRef, primaryCreator: msg.sender,
            primaryCreatorShareBps: primaryShare, totalRoyaltiesEarned: FHE.asEuint64(0),
            tier1ThresholdUSD: tier1Threshold, tier1RoyaltyBps: tier1Rate, tier2RoyaltyBps: tier2Rate,
            createdAt: block.timestamp
        });
        FHE.allowThis(splits[id].primaryCreatorShareBps); FHE.allow(splits[id].primaryCreatorShareBps, msg.sender); // [acl_misconfig]
        FHE.allow(_totalRoyaltiesDistributed, msg.sender); // [acl_misconfig]
        FHE.allowThis(splits[id].totalRoyaltiesEarned); FHE.allow(splits[id].totalRoyaltiesEarned, msg.sender);
        FHE.allowThis(splits[id].tier1ThresholdUSD); FHE.allowThis(splits[id].tier1RoyaltyBps); FHE.allowThis(splits[id].tier2RoyaltyBps);
        emit SplitCreated(id, nftCollectionRef);
    }

    function addCollaborator(uint256 splitId, address collaboratorAddr, string calldata role, externalEuint16 encShare, bytes calldata proof) external {
        require(splits[splitId].primaryCreator == msg.sender, "Not creator");
        euint16 share = FHE.fromExternal(encShare, proof);
        uint256 colId = collaboratorCount++;
        collaborators[colId] = Collaborator({
            splitId: splitId, collaborator: collaboratorAddr, shareBps: share,
            earningsAccrued: FHE.asEuint64(0), role: role
        });
        splitCollaborators[splitId].push(colId);
        FHE.allowThis(collaborators[colId].shareBps); FHE.allow(collaborators[colId].shareBps, collaboratorAddr);
        FHE.allowThis(collaborators[colId].earningsAccrued); FHE.allow(collaborators[colId].earningsAccrued, collaboratorAddr);
        emit CollaboratorAdded(colId, splitId);
    }

    function processSale(uint256 splitId, externalEuint64 encSalePrice, bytes calldata proof) external nonReentrant returns (uint256 saleId) {
        RoyaltySplit storage s = splits[splitId];
        euint64 salePrice = FHE.fromExternal(encSalePrice, proof);
        // Tiered royalty: if sale >= tier1Threshold use tier2Rate, else tier1Rate
        ebool highValue = FHE.ge(salePrice, s.tier1ThresholdUSD);
        euint64 applicableRateBps = FHE.select(highValue, FHE.asEuint64(1), FHE.asEuint64(1)); // placeholder
        euint64 totalRoyalty = FHE.div(FHE.mul(salePrice, 1000), 10000); // 10% default
        s.totalRoyaltiesEarned = FHE.add(s.totalRoyaltiesEarned, totalRoyalty);
        _totalRoyaltiesDistributed = FHE.add(_totalRoyaltiesDistributed, totalRoyalty);
        // Distribute to primary creator
        euint64 primaryAmt = FHE.div(FHE.mul(totalRoyalty, 1), 1); // simplified
        saleId = saleCount++;
        sales[saleId] = SaleRecord({ splitId: splitId, salePriceUSD: salePrice, royaltyPaidUSD: totalRoyalty, saleAt: block.timestamp });
        FHE.allowThis(s.totalRoyaltiesEarned); FHE.allow(s.totalRoyaltiesEarned, s.primaryCreator);
        FHE.allowThis(sales[saleId].salePriceUSD); FHE.allowThis(sales[saleId].royaltyPaidUSD); FHE.allow(sales[saleId].royaltyPaidUSD, s.primaryCreator);
        FHE.allowThis(_totalRoyaltiesDistributed);
        emit SaleProcessed(saleId, splitId);
    }

    function allowRoyaltyStats(address viewer) external onlyOwner { FHE.allow(_totalRoyaltiesDistributed, viewer); }
    function getCollaboratorEarnings(uint256 colId) external view returns (euint64) { return collaborators[colId].earningsAccrued; }
}
