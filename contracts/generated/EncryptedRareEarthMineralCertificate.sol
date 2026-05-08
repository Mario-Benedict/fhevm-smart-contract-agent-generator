// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedRareEarthMineralCertificate
/// @notice Rare earth mineral certification: encrypted grade, content percentage,
///         and batch weights for REE commodities (neodymium, dysprosium, terbium).
contract EncryptedRareEarthMineralCertificate is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum REEType { Neodymium, Dysprosium, Terbium, Praseodymium, Lanthanum, Cerium, Yttrium }
    enum CertStatus { Pending, Certified, Revoked, Expired }

    struct MineralBatch {
        address miner;
        string mineId;
        REEType mineralType;
        string countryOfOrigin;
        euint32 batchWeightKg;          // encrypted batch weight
        euint16 purityPercBps;          // encrypted purity (bps, max 10000)
        euint64 estimatedValueUSD;      // encrypted estimated market value
        euint32 radiationLevel;         // encrypted background radiation (mSv)
        uint256 mineDate;
        CertStatus status;
        address certifier;
    }

    struct TradeRecord {
        uint256 batchId;
        address buyer;
        euint64 tradePriceUSD;          // encrypted trade price
        euint32 quantityKg;             // encrypted traded quantity
        uint256 tradeDate;
    }

    mapping(uint256 => MineralBatch) private batches;
    mapping(uint256 => TradeRecord[]) private tradeHistory;
    mapping(address => bool) public isCertifier;
    mapping(address => bool) public isTrader;

    uint256 public batchCount;
    euint64 private _totalCertifiedValueUSD;
    euint64 private _totalTradedValueUSD;

    event BatchRegistered(uint256 indexed id, REEType mineralType, string mineId);
    event BatchCertified(uint256 indexed id, address certifier);
    event BatchTraded(uint256 indexed id, address buyer);
    event BatchRevoked(uint256 indexed id, string reason);

    modifier onlyCertifier() {
        require(isCertifier[msg.sender] || msg.sender == owner(), "Not certifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCertifiedValueUSD = FHE.asEuint64(0);
        _totalTradedValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalCertifiedValueUSD);
        FHE.allowThis(_totalTradedValueUSD);
        isCertifier[msg.sender] = true;
    }

    function addCertifier(address c) external onlyOwner { isCertifier[c] = true; }
    function addTrader(address t) external onlyOwner { isTrader[t] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerBatch(
        string calldata mineId,
        REEType mineralType,
        string calldata country,
        externalEuint32 encWeight, bytes calldata wProof,
        externalEuint16 encPurity, bytes calldata pProof,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint32 encRadiation, bytes calldata rProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 weight = FHE.fromExternal(encWeight, wProof);
        euint16 purity = FHE.fromExternal(encPurity, pProof);
        euint64 val = FHE.fromExternal(encValue, vProof);
        euint32 radiation = FHE.fromExternal(encRadiation, rProof);
        id = batchCount++;
        batches[id] = MineralBatch({
            miner: msg.sender, mineId: mineId, mineralType: mineralType, countryOfOrigin: country,
            batchWeightKg: weight, purityPercBps: purity, estimatedValueUSD: val,
            radiationLevel: radiation,
            mineDate: block.timestamp, status: CertStatus.Pending, certifier: address(0)
        });
        FHE.allowThis(batches[id].batchWeightKg);
        FHE.allow(batches[id].batchWeightKg, msg.sender);
        FHE.allowThis(batches[id].purityPercBps);
        FHE.allow(batches[id].purityPercBps, msg.sender);
        FHE.allowThis(batches[id].estimatedValueUSD);
        FHE.allow(batches[id].estimatedValueUSD, msg.sender);
        FHE.allowThis(batches[id].radiationLevel);
        emit BatchRegistered(id, mineralType, mineId);
    }

    function certifyBatch(uint256 batchId) external onlyCertifier {
        MineralBatch storage b = batches[batchId];
        require(b.status == CertStatus.Pending, "Not pending");
        b.status = CertStatus.Certified;
        b.certifier = msg.sender;
        _totalCertifiedValueUSD = FHE.add(_totalCertifiedValueUSD, b.estimatedValueUSD);
        FHE.allowThis(_totalCertifiedValueUSD);
        emit BatchCertified(batchId, msg.sender);
    }

    function tradeBatch(
        uint256 batchId,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint32 encQty, bytes calldata qProof
    ) external whenNotPaused nonReentrant {
        require(isTrader[msg.sender], "Not trader");
        MineralBatch storage b = batches[batchId];
        require(b.status == CertStatus.Certified, "Not certified");
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint32 qty = FHE.fromExternal(encQty, qProof);
        TradeRecord memory rec = TradeRecord({
            batchId: batchId, buyer: msg.sender,
            tradePriceUSD: price, quantityKg: qty,
            tradeDate: block.timestamp
        });
        tradeHistory[batchId].push(rec);
        _totalTradedValueUSD = FHE.add(_totalTradedValueUSD, price);
        FHE.allowThis(price);
        FHE.allow(price, b.miner);
        FHE.allow(price, msg.sender);
        FHE.allowThis(qty);
        FHE.allowThis(_totalTradedValueUSD);
        emit BatchTraded(batchId, msg.sender);
    }

    function revokeBatch(uint256 batchId, string calldata reason) external onlyCertifier {
        batches[batchId].status = CertStatus.Revoked;
        emit BatchRevoked(batchId, reason);
    }

    function allowBatchDetails(uint256 batchId, address viewer) external {
        MineralBatch storage b = batches[batchId];
        require(msg.sender == b.miner || isCertifier[msg.sender], "Unauthorized");
        FHE.allow(b.batchWeightKg, viewer);
        FHE.allow(b.purityPercBps, viewer);
        FHE.allow(b.estimatedValueUSD, viewer);
        FHE.allow(b.radiationLevel, viewer);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalCertifiedValueUSD, viewer);
        FHE.allow(_totalTradedValueUSD, viewer);
    }
}
