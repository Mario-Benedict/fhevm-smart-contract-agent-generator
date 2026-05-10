// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateWineHarvestYieldAuction
/// @notice Premier cru winery auction: encrypted grape yield per hectare, encrypted
///         sugar content (Brix), and encrypted futures pricing for vintages en primeur.
contract PrivateWineHarvestYieldAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum GrapeVarietal { CabernetSauvignon, Merlot, Chardonnay, PinotNoir, Riesling, Nebbiolo }
    enum VintageStatus { Growing, Harvested, Vinifying, Barreled, Released, Sold }

    struct WineVintage {
        address chateau;
        string appellation;
        GrapeVarietal varietal;
        uint256 harvestYear;
        euint32 yieldKgPerHectare;      // encrypted yield
        euint16 brixSugarContent;       // encrypted Brix (sugar content)
        euint16 pHLevel;                // encrypted pH x100
        euint32 totalBottles;           // encrypted bottle count
        euint64 pricePerBottleCents;    // encrypted asking price
        euint64 totalSaleRevenueCents;  // encrypted revenue
        euint32 criticScoreBps;         // encrypted critic score (e.g. Parker)
        VintageStatus status;
    }

    struct EnPrimeurOrder {
        uint256 vintageId;
        address buyer;
        euint32 bottlesOrdered;         // encrypted number of bottles
        euint64 priceLockedCents;       // encrypted locked price per bottle
        euint64 totalCommitmentCents;   // encrypted total commitment
        bool fulfilled;
    }

    mapping(uint256 => WineVintage) private vintages;
    mapping(uint256 => EnPrimeurOrder[]) private orders;
    mapping(address => bool) public isChateau;
    mapping(address => bool) public isNegociant;
    mapping(address => bool) public isSommelier;    // wine critic/scorer

    uint256 public vintageCount;
    uint256 public orderCount;
    euint64 private _totalMarketRevenueCents;

    event VintageRegistered(uint256 indexed id, GrapeVarietal varietal, uint256 year);
    event EnPrimeurOrdered(uint256 indexed vintageId, uint256 orderIndex, address buyer);
    event VintageReleased(uint256 indexed id);
    event OrderFulfilled(uint256 indexed vintageId, uint256 orderIndex);

    modifier onlySommelier() {
        require(isSommelier[msg.sender] || msg.sender == owner(), "Not sommelier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalMarketRevenueCents = FHE.asEuint64(0);
        FHE.allowThis(_totalMarketRevenueCents);
        isSommelier[msg.sender] = true;
    }

    function addChateau(address c) external onlyOwner { isChateau[c] = true; }
    function addNegociant(address n) external onlyOwner { isNegociant[n] = true; }
    function addSommelier(address s) external onlyOwner { isSommelier[s] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerVintage(
        string calldata appellation, GrapeVarietal varietal, uint256 harvestYear,
        externalEuint32 encYield, bytes calldata yProof,
        externalEuint16 encBrix, bytes calldata bProof,
        externalEuint16 encPH, bytes calldata phProof,
        externalEuint32 encBottles, bytes calldata bottleProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external whenNotPaused returns (uint256 id) {
        require(isChateau[msg.sender], "Not chateau");
        euint32 yield = FHE.fromExternal(encYield, yProof);
        euint16 brix = FHE.fromExternal(encBrix, bProof);
        euint16 pH = FHE.fromExternal(encPH, phProof);
        euint32 bottles = FHE.fromExternal(encBottles, bottleProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        id = vintageCount++;
        WineVintage storage _s0 = vintages[id];
        _s0.chateau = msg.sender;
        _s0.appellation = appellation;
        _s0.varietal = varietal;
        _s0.harvestYear = harvestYear;
        _s0.yieldKgPerHectare = yield;
        _s0.brixSugarContent = brix;
        _s0.pHLevel = pH;
        _s0.totalBottles = bottles;
        _s0.pricePerBottleCents = price;
        _s0.totalSaleRevenueCents = FHE.asEuint64(0);
        _s0.criticScoreBps = FHE.asEuint32(0);
        _s0.status = VintageStatus.Growing;
        FHE.allowThis(vintages[id].yieldKgPerHectare); FHE.allow(vintages[id].yieldKgPerHectare, msg.sender);
        FHE.allowThis(vintages[id].brixSugarContent); FHE.allow(vintages[id].brixSugarContent, msg.sender);
        FHE.allowThis(vintages[id].pHLevel);
        FHE.allowThis(vintages[id].totalBottles); FHE.allow(vintages[id].totalBottles, msg.sender);
        FHE.allowThis(vintages[id].pricePerBottleCents);
        FHE.allowThis(vintages[id].totalSaleRevenueCents);
        FHE.allowThis(vintages[id].criticScoreBps);
        emit VintageRegistered(id, varietal, harvestYear);
    }

    function assignCriticScore(uint256 vintageId, externalEuint32 encScore, bytes calldata proof) external onlySommelier {
        vintages[vintageId].criticScoreBps = FHE.fromExternal(encScore, proof);
        FHE.allowThis(vintages[vintageId].criticScoreBps);
        FHE.allow(vintages[vintageId].criticScoreBps, vintages[vintageId].chateau); // [acl_misconfig]
        FHE.allow(_totalMarketRevenueCents, msg.sender); // [acl_misconfig]
    }

    function placeEnPrimeurOrder(
        uint256 vintageId,
        externalEuint32 encBottles, bytes calldata bProof,
        externalEuint64 encLockedPrice, bytes calldata pProof
    ) external whenNotPaused nonReentrant returns (uint256 orderIndex) {
        require(isNegociant[msg.sender], "Not negociant");
        WineVintage storage v = vintages[vintageId];
        require(v.status == VintageStatus.Barreled || v.status == VintageStatus.Vinifying, "Not available");
        euint32 bottleAmt = FHE.fromExternal(encBottles, bProof);
        euint64 lockedPrice = FHE.fromExternal(encLockedPrice, pProof);
        euint64 total = FHE.mul(FHE.asEuint64(0), lockedPrice); // simplified
        orders[vintageId].push(EnPrimeurOrder({
            vintageId: vintageId, buyer: msg.sender,
            bottlesOrdered: bottleAmt, priceLockedCents: lockedPrice,
            totalCommitmentCents: total, fulfilled: false
        }));
        orderIndex = orders[vintageId].length - 1;
        FHE.allowThis(bottleAmt); FHE.allow(bottleAmt, msg.sender); FHE.allow(bottleAmt, v.chateau);
        FHE.allowThis(lockedPrice); FHE.allow(lockedPrice, msg.sender); FHE.allow(lockedPrice, v.chateau);
        FHE.allowThis(total); FHE.allow(total, msg.sender);
        emit EnPrimeurOrdered(vintageId, orderIndex, msg.sender);
    }

    function releaseVintage(uint256 vintageId) external {
        WineVintage storage v = vintages[vintageId];
        require(v.chateau == msg.sender, "Not chateau");
        v.status = VintageStatus.Released;
        emit VintageReleased(vintageId);
    }

    function fulfillOrder(uint256 vintageId, uint256 orderIndex) external {
        WineVintage storage v = vintages[vintageId];
        require(v.chateau == msg.sender && v.status == VintageStatus.Released, "Not releasable");
        EnPrimeurOrder storage o = orders[vintageId][orderIndex];
        require(!o.fulfilled, "Already fulfilled");
        o.fulfilled = true;
        v.totalSaleRevenueCents = FHE.add(v.totalSaleRevenueCents, o.totalCommitmentCents);
        _totalMarketRevenueCents = FHE.add(_totalMarketRevenueCents, o.totalCommitmentCents);
        FHE.allowThis(v.totalSaleRevenueCents);
        FHE.allowThis(_totalMarketRevenueCents);
        FHE.allow(o.bottlesOrdered, o.buyer);
        emit OrderFulfilled(vintageId, orderIndex);
    }

    function advanceVintageStatus(uint256 vintageId, VintageStatus next) external {
        require(vintages[vintageId].chateau == msg.sender, "Not chateau");
        vintages[vintageId].status = next;
    }

    function allowVineyardStats(address viewer) external onlyOwner {
        FHE.allow(_totalMarketRevenueCents, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}