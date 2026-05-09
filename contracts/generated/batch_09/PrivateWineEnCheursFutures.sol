// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateWineEnCheursFutures
/// @notice Encrypted en primeur (wine futures) market: hidden vintage quality scores,
///         confidential pricing per case, private allocation to merchant subscribers,
///         and encrypted cellar aging value projections.
contract PrivateWineEnCheursFutures is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum WineRegion { Bordeaux, Burgundy, Champagne, Rhone, Tuscany, Napa, Barossa }
    enum AllocationStatus { Open, Allocated, Released, Shipped }

    struct VintageLot {
        address chateau;
        string vintageName;
        WineRegion region;
        uint32 harvestYear;
        euint32 totalCasesProduced;    // encrypted production
        euint32 casesAllocatedToMarket;// encrypted market allocation
        euint64 futurePricePerCaseUSD; // encrypted futures price
        euint16 vineyardQualityScore;  // encrypted quality score (0-1000)
        euint64 projectedReleasePriceUSD; // encrypted projected release price
        AllocationStatus status;
        uint256 offeringStart;
        uint256 deliveryDate;
    }

    struct FuturesSubscription {
        uint256 lotId;
        address subscriber;
        euint32 casesSubscribed;       // encrypted cases ordered
        euint64 totalCommitmentUSD;    // encrypted total payment commitment
        euint64 depositPaidUSD;        // encrypted deposit paid
        bool delivered;
    }

    mapping(uint256 => VintageLot) private lots;
    mapping(uint256 => FuturesSubscription) private subscriptions;
    mapping(address => bool) public isNegociant;

    uint256 public lotCount;
    uint256 public subscriptionCount;
    euint64 private _totalFuturesSalesUSD;
    euint64 private _totalDepositsHeldUSD;

    event VintageLotCreated(uint256 indexed id, string vintageName, WineRegion region, uint32 harvestYear);
    event FuturesSubscribed(uint256 indexed subId, uint256 lotId, address subscriber);
    event LotDelivered(uint256 indexed lotId);

    modifier onlyNegociant() {
        require(isNegociant[msg.sender] || msg.sender == owner(), "Not negociant");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalFuturesSalesUSD = FHE.asEuint64(0);
        _totalDepositsHeldUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalFuturesSalesUSD);
        FHE.allowThis(_totalDepositsHeldUSD);
        isNegociant[msg.sender] = true;
    }

    function addNegociant(address n) external onlyOwner { isNegociant[n] = true; }

    function createVintageLot(
        string calldata vintageName,
        WineRegion region,
        uint32 harvestYear,
        externalEuint32 encTotalCases, bytes calldata tcProof,
        externalEuint32 encAllocated, bytes calldata alProof,
        externalEuint64 encFuturePrice, bytes calldata fpProof,
        externalEuint16 encQuality, bytes calldata qProof,
        externalEuint64 encProjRelease, bytes calldata prProof,
        uint256 deliveryDays
    ) external onlyNegociant returns (uint256 id) {
        euint32 totalCases = FHE.fromExternal(encTotalCases, tcProof);
        euint32 allocated = FHE.fromExternal(encAllocated, alProof);
        euint64 futurePrice = FHE.fromExternal(encFuturePrice, fpProof);
        euint16 quality = FHE.fromExternal(encQuality, qProof);
        euint64 projRelease = FHE.fromExternal(encProjRelease, prProof);
        id = lotCount++;
        VintageLot storage _s0 = lots[id];
        _s0.chateau = msg.sender;
        _s0.vintageName = vintageName;
        _s0.region = region;
        _s0.harvestYear = harvestYear;
        _s0.totalCasesProduced = totalCases;
        _s0.casesAllocatedToMarket = allocated;
        _s0.futurePricePerCaseUSD = futurePrice;
        _s0.vineyardQualityScore = quality;
        _s0.projectedReleasePriceUSD = projRelease;
        _s0.status = AllocationStatus.Open;
        _s0.offeringStart = block.timestamp;
        _s0.deliveryDate = block.timestamp + deliveryDays * 1 days;
        FHE.allowThis(lots[id].totalCasesProduced); FHE.allow(lots[id].totalCasesProduced, msg.sender);
        FHE.allowThis(lots[id].casesAllocatedToMarket); FHE.allow(lots[id].casesAllocatedToMarket, msg.sender);
        FHE.allowThis(lots[id].futurePricePerCaseUSD); FHE.allow(lots[id].futurePricePerCaseUSD, msg.sender);
        FHE.allowThis(lots[id].vineyardQualityScore);
        FHE.allowThis(lots[id].projectedReleasePriceUSD); FHE.allow(lots[id].projectedReleasePriceUSD, msg.sender);
        emit VintageLotCreated(id, vintageName, region, harvestYear);
    }

    function subscribeFutures(
        uint256 lotId,
        externalEuint32 encCases, bytes calldata casesProof,
        externalEuint64 encDeposit, bytes calldata depositProof
    ) external nonReentrant returns (uint256 subId) {
        VintageLot storage lot = lots[lotId];
        require(lot.status == AllocationStatus.Open, "Not open");
        euint32 cases = FHE.fromExternal(encCases, casesProof);
        euint64 deposit = FHE.fromExternal(encDeposit, depositProof);
        euint64 totalCommitment = FHE.mul(FHE.asEuint64(1), lot.futurePricePerCaseUSD); // proxy 1 case
        subId = subscriptionCount++;
        subscriptions[subId] = FuturesSubscription({
            lotId: lotId, subscriber: msg.sender, casesSubscribed: cases,
            totalCommitmentUSD: totalCommitment, depositPaidUSD: deposit, delivered: false
        });
        _totalFuturesSalesUSD = FHE.add(_totalFuturesSalesUSD, totalCommitment);
        _totalDepositsHeldUSD = FHE.add(_totalDepositsHeldUSD, deposit);
        FHE.allowThis(subscriptions[subId].casesSubscribed); FHE.allow(subscriptions[subId].casesSubscribed, msg.sender); FHE.allow(subscriptions[subId].casesSubscribed, lot.chateau);
        FHE.allowThis(subscriptions[subId].totalCommitmentUSD); FHE.allow(subscriptions[subId].totalCommitmentUSD, msg.sender);
        FHE.allowThis(subscriptions[subId].depositPaidUSD); FHE.allow(subscriptions[subId].depositPaidUSD, msg.sender);
        FHE.allowThis(_totalFuturesSalesUSD);
        FHE.allowThis(_totalDepositsHeldUSD);
        emit FuturesSubscribed(subId, lotId, msg.sender);
    }

    function deliverLot(uint256 lotId) external onlyNegociant {
        VintageLot storage lot = lots[lotId];
        require(block.timestamp >= lot.deliveryDate, "Not delivery time");
        lot.status = AllocationStatus.Shipped;
        emit LotDelivered(lotId);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalFuturesSalesUSD, viewer);
        FHE.allow(_totalDepositsHeldUSD, viewer);
    }
}
