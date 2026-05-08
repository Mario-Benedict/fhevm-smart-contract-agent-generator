// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateLivestockGeneticsMarketplace
/// @notice Encrypted livestock genetics marketplace: hidden embryo production costs,
///         confidential genomic EBV scores, private semen straw pricing, and encrypted
///         bloodline royalty chains for elite genetics.
contract PrivateLivestockGeneticsMarketplace is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum GeneticMaterial { FrozenSemen, FreshSemen, EmbryoFresh, EmbryoFrozen, SexedSemen }
    enum Species { Cattle, Sheep, Goats, Pigs, Horses, Alpacas }

    struct GeneticLot {
        address breeder;
        Species species;
        GeneticMaterial materialType;
        string sireId;
        string damId;
        euint32 unitCount;             // encrypted number of straws/embryos
        euint64 pricePerUnitUSD;       // encrypted price per unit
        euint64 totalLotValueUSD;      // encrypted total lot value
        euint16 ebvRankingBps;         // encrypted EBV ranking score
        euint8  genomicTestScore;      // encrypted genomic testing score
        euint64 bloodlineRoyaltyBps;   // encrypted royalty to original genetics owner
        bool verified;
    }

    struct GeneticPurchase {
        uint256 lotId;
        address buyer;
        euint32 unitsPurchased;        // encrypted units
        euint64 totalPaidUSD;          // encrypted total cost
        euint64 royaltyPaidUSD;        // encrypted royalty paid
        uint256 purchasedAt;
    }

    mapping(uint256 => GeneticLot) private lots;
    mapping(uint256 => GeneticPurchase) private purchases;
    mapping(address => bool) public isGeneticsAuthority;

    uint256 public lotCount;
    uint256 public purchaseCount;
    euint64 private _totalMarketplaceValueUSD;
    euint64 private _totalRoyaltiesPaidUSD;

    event LotListed(uint256 indexed id, Species species, GeneticMaterial materialType);
    event GeneticsPurchased(uint256 indexed purchaseId, uint256 lotId, address buyer);

    modifier onlyGeneticsAuthority() {
        require(isGeneticsAuthority[msg.sender] || msg.sender == owner(), "Not genetics authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalMarketplaceValueUSD = FHE.asEuint64(0);
        _totalRoyaltiesPaidUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalMarketplaceValueUSD);
        FHE.allowThis(_totalRoyaltiesPaidUSD);
        isGeneticsAuthority[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addAuthority(address a) external onlyOwner { isGeneticsAuthority[a] = true; }

    function listGeneticLot(
        Species species, GeneticMaterial materialType, string calldata sireId, string calldata damId,
        externalEuint32 encUnits, bytes calldata uProof,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint16 encEBV, bytes calldata ebvProof,
        externalEuint8 encGenomic, bytes calldata gProof,
        externalEuint64 encRoyaltyBps, bytes calldata rProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 units = FHE.fromExternal(encUnits, uProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint16 ebv = FHE.fromExternal(encEBV, ebvProof);
        euint8 genomic = FHE.fromExternal(encGenomic, gProof);
        euint64 royaltyBps = FHE.fromExternal(encRoyaltyBps, rProof);
        euint64 totalLotVal = FHE.mul(FHE.asEuint64(1), price);
        id = lotCount++;
        lots[id] = GeneticLot({
            breeder: msg.sender, species: species, materialType: materialType,
            sireId: sireId, damId: damId, unitCount: units, pricePerUnitUSD: price,
            totalLotValueUSD: totalLotVal, ebvRankingBps: ebv, genomicTestScore: genomic,
            bloodlineRoyaltyBps: royaltyBps, verified: false
        });
        _totalMarketplaceValueUSD = FHE.add(_totalMarketplaceValueUSD, totalLotVal);
        FHE.allowThis(lots[id].unitCount); FHE.allow(lots[id].unitCount, msg.sender);
        FHE.allowThis(lots[id].pricePerUnitUSD); FHE.allow(lots[id].pricePerUnitUSD, msg.sender);
        FHE.allowThis(lots[id].totalLotValueUSD); FHE.allow(lots[id].totalLotValueUSD, msg.sender);
        FHE.allowThis(lots[id].ebvRankingBps);
        FHE.allowThis(lots[id].genomicTestScore);
        FHE.allowThis(lots[id].bloodlineRoyaltyBps);
        FHE.allowThis(_totalMarketplaceValueUSD);
        emit LotListed(id, species, materialType);
    }

    function verifyLot(uint256 lotId) external onlyGeneticsAuthority {
        lots[lotId].verified = true;
        FHE.allow(lots[lotId].ebvRankingBps, msg.sender);
        FHE.allow(lots[lotId].genomicTestScore, msg.sender);
    }

    function purchaseGenetics(
        uint256 lotId,
        externalEuint32 encUnits, bytes calldata uProof
    ) external whenNotPaused nonReentrant returns (uint256 purchaseId) {
        GeneticLot storage l = lots[lotId];
        require(l.verified, "Not verified");
        euint32 units = FHE.fromExternal(encUnits, uProof);
        euint64 totalPaid = FHE.mul(FHE.asEuint64(1), l.pricePerUnitUSD);
        euint64 royaltyPaid = FHE.div(totalPaid, 20); // 5% fixed royalty (plaintext divisor)
        purchaseId = purchaseCount++;
        purchases[purchaseId] = GeneticPurchase({
            lotId: lotId, buyer: msg.sender, unitsPurchased: units,
            totalPaidUSD: totalPaid, royaltyPaidUSD: royaltyPaid, purchasedAt: block.timestamp
        });
        _totalRoyaltiesPaidUSD = FHE.add(_totalRoyaltiesPaidUSD, royaltyPaid);
        FHE.allowThis(purchases[purchaseId].unitsPurchased); FHE.allow(purchases[purchaseId].unitsPurchased, msg.sender);
        FHE.allowThis(purchases[purchaseId].totalPaidUSD); FHE.allow(purchases[purchaseId].totalPaidUSD, msg.sender); FHE.allow(purchases[purchaseId].totalPaidUSD, l.breeder);
        FHE.allowThis(purchases[purchaseId].royaltyPaidUSD); FHE.allow(purchases[purchaseId].royaltyPaidUSD, l.breeder);
        FHE.allowThis(_totalRoyaltiesPaidUSD);
        emit GeneticsPurchased(purchaseId, lotId, msg.sender);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalMarketplaceValueUSD, viewer);
        FHE.allow(_totalRoyaltiesPaidUSD, viewer);
    }
}
