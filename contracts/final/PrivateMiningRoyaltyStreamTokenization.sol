// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMiningRoyaltyStreamTokenization
/// @notice Mining royalty tokenization where streaming royalty payments,
///         production volumes, commodity prices, and depletion rates are encrypted.
contract PrivateMiningRoyaltyStreamTokenization is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum CommodityType { GOLD, SILVER, COPPER, IRON_ORE, COAL, LITHIUM, PLATINUM, PALLADIUM }
    enum RoyaltyType { NSR, GR, NPI, STREAM, ROYALTY_ON_REVENUE }

    struct MiningRoyaltyToken {
        string mineName;
        string jurisdiction;
        CommodityType commodity;
        RoyaltyType royaltyType;
        address royaltyOwner;
        address miningCompany;
        euint64 royaltyRateBps;        // encrypted % of production
        euint64 productionAnnualOz;    // encrypted annual production (oz or tonnes)
        euint64 spotPriceUSD;          // encrypted current commodity price
        euint64 annualRoyaltyUSD;      // encrypted annual royalty income
        euint64 npvRoyaltyStreamUSD;   // encrypted NPV of future royalties
        euint64 reservesRemainingOz;   // encrypted remaining mine life
        euint32 mineLifeYears;         // encrypted estimated mine life
        euint8  technicalRiskScore;    // encrypted geological risk 0-100
        uint256 tokenizationDate;
        bool active;
    }

    struct TokenHolder {
        euint64 tokensOwned;           // encrypted balance
        euint64 royaltiesEarned;       // encrypted cumulative receipts
        euint64 costBasisPerToken;     // encrypted acquisition cost
        bool accredited;
    }

    mapping(uint256 => MiningRoyaltyToken) private royaltyTokens;
    mapping(uint256 => mapping(address => TokenHolder)) private holders;
    mapping(address => bool) public isMiningAuditor;
    mapping(address => bool) public isRoyaltyManager;
    uint256 public tokenCount;
    euint64 private _totalNPVPortfolio;
    euint64 private _totalRoyaltiesDistributed;

    event RoyaltyTokenCreated(uint256 indexed tokenId, CommodityType commodity);
    event TokensPurchased(uint256 indexed tokenId, address holder);
    event RoyaltyDistributed(uint256 indexed tokenId);
    event ProductionUpdated(uint256 indexed tokenId);

    constructor() Ownable(msg.sender) {
        _totalNPVPortfolio = FHE.asEuint64(0);
        _totalRoyaltiesDistributed = FHE.asEuint64(0);
        FHE.allowThis(_totalNPVPortfolio);
        FHE.allowThis(_totalRoyaltiesDistributed);
        isMiningAuditor[msg.sender] = true;
        isRoyaltyManager[msg.sender] = true;
    }

    function addAuditor(address a) external onlyOwner { isMiningAuditor[a] = true; }
    function addManager(address m) external onlyOwner { isRoyaltyManager[m] = true; }

    function createRoyaltyToken(
        string calldata mineName,
        string calldata jurisdiction,
        CommodityType commodity,
        RoyaltyType royaltyType,
        address miningCompany,
        externalEuint64 encRate,       bytes calldata rProof,
        externalEuint64 encProduction, bytes calldata prodProof,
        externalEuint64 encSpotPrice,  bytes calldata spProof,
        externalEuint64 encNPV,        bytes calldata npvProof,
        externalEuint64 encReserves,   bytes calldata resProof,
        externalEuint32 encMineLife,   bytes calldata mlProof,
        externalEuint8  encTechRisk,   bytes calldata trProof
    ) external returns (uint256 tokenId) {
        require(isRoyaltyManager[msg.sender], "Not manager");
        euint64 rate       = FHE.fromExternal(encRate, rProof);
        euint64 production = FHE.fromExternal(encProduction, prodProof);
        euint64 spotPrice  = FHE.fromExternal(encSpotPrice, spProof);
        euint64 npv        = FHE.fromExternal(encNPV, npvProof);
        euint64 reserves   = FHE.fromExternal(encReserves, resProof);
        euint32 mineLife   = FHE.fromExternal(encMineLife, mlProof);
        euint8  techRisk   = FHE.fromExternal(encTechRisk, trProof);
        euint64 annualRoyalty = FHE.div(FHE.mul(FHE.mul(production, spotPrice), rate), 10000);
        tokenId = tokenCount++;
        MiningRoyaltyToken storage _s0 = royaltyTokens[tokenId];
        _s0.mineName = mineName;
        _s0.jurisdiction = jurisdiction;
        _s0.commodity = commodity;
        _s0.royaltyType = royaltyType;
        _s0.royaltyOwner = msg.sender;
        _s0.miningCompany = miningCompany;
        _s0.royaltyRateBps = rate;
        _s0.productionAnnualOz = production;
        _s0.spotPriceUSD = spotPrice;
        _s0.annualRoyaltyUSD = annualRoyalty;
        _s0.npvRoyaltyStreamUSD = npv;
        _s0.reservesRemainingOz = reserves;
        _s0.mineLifeYears = mineLife;
        _s0.technicalRiskScore = techRisk;
        _s0.tokenizationDate = block.timestamp;
        _s0.active = true;
        _totalNPVPortfolio = FHE.add(_totalNPVPortfolio, npv);
        FHE.allowThis(royaltyTokens[tokenId].royaltyRateBps);
        FHE.allow(royaltyTokens[tokenId].royaltyRateBps, msg.sender); // [acl_misconfig]
        FHE.allow(_totalNPVPortfolio, msg.sender); // [acl_misconfig]
        FHE.allow(_totalRoyaltiesDistributed, msg.sender); // [acl_misconfig]
        FHE.allowThis(royaltyTokens[tokenId].productionAnnualOz);
        FHE.allowThis(royaltyTokens[tokenId].spotPriceUSD);
        FHE.allowThis(royaltyTokens[tokenId].annualRoyaltyUSD);
        FHE.allow(royaltyTokens[tokenId].annualRoyaltyUSD, msg.sender);
        FHE.allowThis(royaltyTokens[tokenId].npvRoyaltyStreamUSD);
        FHE.allow(royaltyTokens[tokenId].npvRoyaltyStreamUSD, msg.sender);
        FHE.allowThis(royaltyTokens[tokenId].reservesRemainingOz);
        FHE.allowThis(royaltyTokens[tokenId].mineLifeYears);
        FHE.allowThis(royaltyTokens[tokenId].technicalRiskScore);
        FHE.allowThis(_totalNPVPortfolio);
        emit RoyaltyTokenCreated(tokenId, commodity);
    }

    function purchaseTokens(
        uint256 tokenId,
        bool accredited,
        externalEuint64 encTokens,    bytes calldata tkProof,
        externalEuint64 encCostBasis, bytes calldata cbProof
    ) external nonReentrant {
        euint64 tokens    = FHE.fromExternal(encTokens, tkProof);
        euint64 costBasis = FHE.fromExternal(encCostBasis, cbProof);
        if (!FHE.isInitialized(holders[tokenId][msg.sender].tokensOwned)) {
            holders[tokenId][msg.sender].tokensOwned = FHE.asEuint64(0);
            holders[tokenId][msg.sender].royaltiesEarned = FHE.asEuint64(0);
            FHE.allowThis(holders[tokenId][msg.sender].tokensOwned);
            FHE.allowThis(holders[tokenId][msg.sender].royaltiesEarned);
        }
        holders[tokenId][msg.sender].tokensOwned = FHE.add(holders[tokenId][msg.sender].tokensOwned, tokens);
        holders[tokenId][msg.sender].costBasisPerToken = costBasis;
        holders[tokenId][msg.sender].accredited = accredited;
        FHE.allowThis(holders[tokenId][msg.sender].tokensOwned);
        FHE.allow(holders[tokenId][msg.sender].tokensOwned, msg.sender);
        FHE.allowThis(holders[tokenId][msg.sender].costBasisPerToken);
        FHE.allow(holders[tokenId][msg.sender].costBasisPerToken, msg.sender);
        emit TokensPurchased(tokenId, msg.sender);
    }

    function updateProduction(
        uint256 tokenId,
        externalEuint64 encNewProduction, bytes calldata prodProof,
        externalEuint64 encNewSpotPrice,  bytes calldata spProof
    ) external {
        require(isMiningAuditor[msg.sender], "Not auditor");
        royaltyTokens[tokenId].productionAnnualOz = FHE.fromExternal(encNewProduction, prodProof);
        royaltyTokens[tokenId].spotPriceUSD = FHE.fromExternal(encNewSpotPrice, spProof);
        royaltyTokens[tokenId].annualRoyaltyUSD = FHE.div(
            FHE.mul(FHE.mul(royaltyTokens[tokenId].productionAnnualOz, royaltyTokens[tokenId].spotPriceUSD),
                    royaltyTokens[tokenId].royaltyRateBps), 10000
        );
        FHE.allowThis(royaltyTokens[tokenId].productionAnnualOz);
        FHE.allowThis(royaltyTokens[tokenId].spotPriceUSD);
        FHE.allowThis(royaltyTokens[tokenId].annualRoyaltyUSD);
        emit ProductionUpdated(tokenId);
    }

    function distributeRoyalty(uint256 tokenId, address holder) external nonReentrant {
        require(isRoyaltyManager[msg.sender], "Not manager");
        euint64 holderShare = FHE.mul(holders[tokenId][holder].tokensOwned, royaltyTokens[tokenId].annualRoyaltyUSD); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        holders[tokenId][holder].royaltiesEarned = FHE.add(holders[tokenId][holder].royaltiesEarned, holderShare);
        _totalRoyaltiesDistributed = FHE.add(_totalRoyaltiesDistributed, holderShare);
        FHE.allowThis(holders[tokenId][holder].royaltiesEarned);
        FHE.allow(holders[tokenId][holder].royaltiesEarned, holder);
        FHE.allowThis(_totalRoyaltiesDistributed);
        emit RoyaltyDistributed(tokenId);
    }

    function allowPortfolioView(address viewer) external onlyOwner {
        FHE.allow(_totalNPVPortfolio, viewer);
        FHE.allow(_totalRoyaltiesDistributed, viewer);
    }
}
