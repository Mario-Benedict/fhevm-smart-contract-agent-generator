// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateMiningRoyaltyStreamToken
/// @notice Encrypted mining royalty streaming: hidden ore grades, private
///         production volumes, confidential streaming agreement terms,
///         and encrypted royalty waterfall distributions.
contract PrivateMiningRoyaltyStreamToken is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public constant name = "Mining Royalty Stream";
    string public constant symbol = "MRS";
    uint8  public constant decimals = 18;

    enum MineralType { Gold, Silver, Copper, Lithium, Cobalt, Platinum, PalladiumMetal }
    enum RoyaltyStructure { NPI, NSR, StreamingAgreement, OverridingRoyalty }

    struct MiningAsset {
        address miningCompany;
        MineralType mineral;
        RoyaltyStructure structure;
        string mineRef;
        string country;
        euint64 reservesEstTonnes;     // encrypted reserves
        euint64 annualProductionTonnes;// encrypted production
        euint64 royaltyRateBps;        // encrypted royalty rate
        euint64 mineralPriceUSDPerTonne; // encrypted spot price
        euint16 oreGrade;              // encrypted ore grade
        bool active;
    }

    struct StreamingDeal {
        uint256 assetId;
        address streamingBuyer;
        euint64 upfrontPaymentUSD;     // encrypted upfront
        euint64 streamPricePerTonneUSD;// encrypted stream price
        euint64 totalStreamedTonnes;   // encrypted delivered
        euint64 totalPaidUSD;          // encrypted total paid
        uint256 dealDate;
        uint256 termYears;
    }

    mapping(address => euint64) private _balances;
    mapping(uint256 => MiningAsset) private assets;
    mapping(uint256 => StreamingDeal) private deals;

    euint64 private _totalSupply;
    euint64 private _totalRoyaltyRevenue;
    euint64 private _totalStreamingVolumeUSD;

    uint256 public assetCount;
    uint256 public dealCount;

    event Transfer(address indexed from, address indexed to);
    event AssetRegistered(uint256 indexed id, MineralType mineral);
    event StreamingDealCreated(uint256 indexed dealId, uint256 assetId);
    event RoyaltyDistributed(uint256 indexed assetId, uint256 distributedAt);

    modifier onlyMiningCompany(uint256 assetId) {
        require(assets[assetId].miningCompany == msg.sender, "Not mining company");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _totalRoyaltyRevenue = FHE.asEuint64(0);
        _totalStreamingVolumeUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply); FHE.allowThis(_totalRoyaltyRevenue); FHE.allowThis(_totalStreamingVolumeUSD);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerMiningAsset(
        MineralType mineral, RoyaltyStructure structure,
        string calldata mineRef, string calldata country,
        externalEuint64 encReserves,    bytes calldata rProof,
        externalEuint64 encProduction,  bytes calldata pProof,
        externalEuint64 encRoyaltyRate, bytes calldata rrProof,
        externalEuint64 encMineralPrice,bytes calldata mpProof,
        externalEuint16 encOreGrade,    bytes calldata ogProof
    ) external returns (uint256 id) {
        euint64 reserves     = FHE.fromExternal(encReserves, rProof);
        euint64 reservesWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 reservesExposure = FHE.sub(reservesWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint64 production   = FHE.fromExternal(encProduction, pProof);
        euint64 royaltyRate  = FHE.fromExternal(encRoyaltyRate, rrProof);
        euint64 mineralPrice = FHE.fromExternal(encMineralPrice, mpProof);
        euint16 oreGrade     = FHE.fromExternal(encOreGrade, ogProof);
        id = assetCount++;
        assets[id].miningCompany = msg.sender;
        assets[id].mineral = mineral;
        assets[id].structure = structure;
        assets[id].mineRef = mineRef;
        assets[id].country = country;
        assets[id].reservesEstTonnes = reserves;
        assets[id].annualProductionTonnes = production;
        assets[id].royaltyRateBps = royaltyRate;
        assets[id].mineralPriceUSDPerTonne = mineralPrice;
        assets[id].oreGrade = oreGrade;
        assets[id].active = true;
        FHE.allowThis(assets[id].reservesEstTonnes); FHE.allow(assets[id].reservesEstTonnes, msg.sender);
        FHE.allowThis(assets[id].annualProductionTonnes); FHE.allow(assets[id].annualProductionTonnes, msg.sender);
        FHE.allowThis(assets[id].royaltyRateBps); FHE.allow(assets[id].royaltyRateBps, msg.sender);
        FHE.allowThis(assets[id].mineralPriceUSDPerTonne); FHE.allow(assets[id].mineralPriceUSDPerTonne, msg.sender);
        FHE.allowThis(assets[id].oreGrade);
        emit AssetRegistered(id, mineral);
    }

    function createStreamingDeal(
        uint256 assetId, address streamingBuyer,
        externalEuint64 encUpfront,   bytes calldata uProof,
        externalEuint64 encStreamPrice, bytes calldata spProof,
        uint256 termYears
    ) external onlyMiningCompany(assetId) whenNotPaused returns (uint256 dealId) {
        euint64 upfront     = FHE.fromExternal(encUpfront, uProof);
        euint64 streamPrice = FHE.fromExternal(encStreamPrice, spProof);
        // Mint MRS tokens to streaming buyer proportional to upfront
        if (!FHE.isInitialized(_balances[streamingBuyer])) { _balances[streamingBuyer] = FHE.asEuint64(0); FHE.allowThis(_balances[streamingBuyer]); }
        _balances[streamingBuyer] = FHE.add(_balances[streamingBuyer], upfront);
        _totalSupply = FHE.add(_totalSupply, upfront);
        _totalStreamingVolumeUSD = FHE.add(_totalStreamingVolumeUSD, upfront);
        dealId = dealCount++;
        deals[dealId] = StreamingDeal({
            assetId: assetId, streamingBuyer: streamingBuyer, upfrontPaymentUSD: upfront,
            streamPricePerTonneUSD: streamPrice, totalStreamedTonnes: FHE.asEuint64(0),
            totalPaidUSD: FHE.asEuint64(0), dealDate: block.timestamp, termYears: termYears
        });
        FHE.allowThis(_balances[streamingBuyer]); FHE.allow(_balances[streamingBuyer], streamingBuyer);
        FHE.allowThis(deals[dealId].upfrontPaymentUSD); FHE.allow(deals[dealId].upfrontPaymentUSD, streamingBuyer);
        FHE.allowThis(deals[dealId].streamPricePerTonneUSD); FHE.allow(deals[dealId].streamPricePerTonneUSD, streamingBuyer);
        FHE.allowThis(deals[dealId].totalStreamedTonnes); FHE.allow(deals[dealId].totalStreamedTonnes, streamingBuyer);
        FHE.allowThis(deals[dealId].totalPaidUSD); FHE.allow(deals[dealId].totalPaidUSD, streamingBuyer);
        FHE.allowThis(_totalSupply); FHE.allowThis(_totalStreamingVolumeUSD);
        emit StreamingDealCreated(dealId, assetId);
    }

    function distributeRoyalty(uint256 dealId, externalEuint64 encTonnesProduced, bytes calldata proof) external whenNotPaused nonReentrant {
        StreamingDeal storage d = deals[dealId];
        MiningAsset storage a = assets[d.assetId];
        require(a.miningCompany == msg.sender, "Not mine operator");
        euint64 tonnes = FHE.fromExternal(encTonnesProduced, proof);
        euint64 royaltyAmt = FHE.div(FHE.mul(tonnes, FHE.mul(a.mineralPriceUSDPerTonne, a.royaltyRateBps)), 10000);
        d.totalStreamedTonnes = FHE.add(d.totalStreamedTonnes, tonnes);
        d.totalPaidUSD = FHE.add(d.totalPaidUSD, royaltyAmt);
        _totalRoyaltyRevenue = FHE.add(_totalRoyaltyRevenue, royaltyAmt);
        FHE.allowThis(d.totalStreamedTonnes); FHE.allow(d.totalStreamedTonnes, d.streamingBuyer);
        FHE.allowThis(d.totalPaidUSD); FHE.allow(d.totalPaidUSD, d.streamingBuyer);
        FHE.allow(royaltyAmt, d.streamingBuyer); // [acl_misconfig]
        FHE.allow(_totalSupply, msg.sender); // [acl_misconfig]
        FHE.allow(_totalRoyaltyRevenue, msg.sender); // [acl_misconfig]
        FHE.allowThis(_totalRoyaltyRevenue);
        emit RoyaltyDistributed(d.assetId, block.timestamp);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external whenNotPaused {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 eff = FHE.select(sufficient, amt, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], eff);
        _balances[to] = FHE.add(_balances[to], eff);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function allowStreamStats(address viewer) external onlyOwner {
        FHE.allow(_totalRoyaltyRevenue, viewer); FHE.allow(_totalStreamingVolumeUSD, viewer);
    }
    function balanceOf(address a) external view returns (euint64) { return _balances[a]; }
}
