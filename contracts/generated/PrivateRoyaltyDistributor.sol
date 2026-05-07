// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title PrivateRoyaltyDistributor
/// @notice NFT creators receive encrypted royalty payments proportional to their
///         collection's sales volume, distributed privately per creator.
contract PrivateRoyaltyDistributor is ZamaEthereumConfig, Ownable {
    struct Collection {
        address creator;
        IERC721 nftContract;
        euint64 royaltyRateBps;  // encrypted
        euint64 accumulatedRoyalties;
        euint64 totalSalesVolume;
        bool active;
    }

    mapping(bytes32 => Collection) private collections;
    mapping(address => euint64) private _creatorBalance;
    euint64 private _platformRevenue;
    uint16 public platformCutBps;

    event CollectionRegistered(bytes32 indexed colId, address creator);
    event RoyaltyRecorded(bytes32 indexed colId);
    event RoyaltyWithdrawn(address creator);

    constructor(uint16 _platformCut) Ownable(msg.sender) {
        platformCutBps = _platformCut;
        _platformRevenue = FHE.asEuint64(0);
        FHE.allowThis(_platformRevenue);
    }

    function registerCollection(
        address nftAddr,
        externalEuint64 encRateBps, bytes calldata proof
    ) external returns (bytes32 colId) {
        euint64 rate = FHE.fromExternal(encRateBps, proof);
        colId = keccak256(abi.encodePacked(nftAddr, msg.sender));
        collections[colId] = Collection({
            creator: msg.sender,
            nftContract: IERC721(nftAddr),
            royaltyRateBps: rate,
            accumulatedRoyalties: FHE.asEuint64(0),
            totalSalesVolume: FHE.asEuint64(0),
            active: true
        });
        FHE.allowThis(collections[colId].royaltyRateBps);
        FHE.allow(collections[colId].royaltyRateBps, msg.sender);
        FHE.allowThis(collections[colId].accumulatedRoyalties);
        FHE.allowThis(collections[colId].totalSalesVolume);
        emit CollectionRegistered(colId, msg.sender);
    }

    function recordSale(bytes32 colId, externalEuint64 encSalePrice, bytes calldata proof) external onlyOwner {
        Collection storage c = collections[colId];
        require(c.active, "Not active");
        euint64 salePrice = FHE.fromExternal(encSalePrice, proof);
        // royalty = salePrice * rate / 10000
        euint64 royalty = FHE.div(FHE.mul(salePrice, c.royaltyRateBps), 10000);
        euint64 platformCut = FHE.div(FHE.mul(royalty, FHE.asEuint64(uint64(platformCutBps))), 10000);
        euint64 creatorRoyalty = FHE.sub(royalty, platformCut);
        c.accumulatedRoyalties = FHE.add(c.accumulatedRoyalties, creatorRoyalty);
        c.totalSalesVolume = FHE.add(c.totalSalesVolume, salePrice);
        _platformRevenue = FHE.add(_platformRevenue, platformCut);
        _creatorBalance[c.creator] = FHE.add(_creatorBalance[c.creator], creatorRoyalty);
        FHE.allowThis(c.accumulatedRoyalties);
        FHE.allowThis(c.totalSalesVolume);
        FHE.allowThis(_platformRevenue);
        FHE.allowThis(_creatorBalance[c.creator]);
        FHE.allow(_creatorBalance[c.creator], c.creator);
        emit RoyaltyRecorded(colId);
    }

    function withdrawRoyalties() external {
        euint64 bal = _creatorBalance[msg.sender];
        _creatorBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_creatorBalance[msg.sender]);
        FHE.allow(bal, msg.sender);
        emit RoyaltyWithdrawn(msg.sender);
    }

    function allowCollectionStats(bytes32 colId, address viewer) external {
        require(collections[colId].creator == msg.sender || msg.sender == owner(), "Unauthorized");
        FHE.allow(collections[colId].accumulatedRoyalties, viewer);
        FHE.allow(collections[colId].totalSalesVolume, viewer);
    }
}
