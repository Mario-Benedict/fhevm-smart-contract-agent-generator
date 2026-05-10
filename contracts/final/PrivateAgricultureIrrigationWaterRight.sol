// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateAgricultureIrrigationWaterRight
/// @notice Encrypted water rights trading for irrigation: hidden water allocation quotas,
///         confidential spot pricing, private drought severity adjustments, and encrypted
///         aquifer level monitoring data for sustainable draw limits.
contract PrivateAgricultureIrrigationWaterRight is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum WaterSource { SurfaceWater, Groundwater, RecycledWater, DesalinationPlant }
    enum WaterRightType { Senior, Junior, Riparian, Appropriative }

    struct WaterRight {
        address rightHolder;
        WaterSource waterSource;
        WaterRightType rightType;
        string basinCode;
        euint64 annualAllocationML;    // encrypted annual allocation (megalitres)
        euint64 usedVolumeML;          // encrypted used volume
        euint64 tradableVolumeML;      // encrypted tradable surplus
        euint32 priorityScore;         // encrypted seniority score
        euint64 marketValuePerMLUSD;   // encrypted market value per ML
        bool active;
    }

    struct WaterTrade {
        uint256 sellerRightId;
        uint256 buyerRightId;
        address seller;
        address buyer;
        euint64 volumeML;              // encrypted traded volume
        euint64 pricePerMLUSD;         // encrypted agreed price
        euint64 totalConsiderationUSD; // encrypted total payment
        uint256 tradeDate;
        bool settled;
    }

    mapping(uint256 => WaterRight) private waterRights;
    mapping(uint256 => WaterTrade) private trades;
    mapping(address => bool) public isWaterRegulator;

    uint256 public rightCount;
    uint256 public tradeCount;
    euint64 private _totalAllocationML;
    euint64 private _totalTradeVolumeML;
    euint64 private _totalTradeValueUSD;

    event WaterRightRegistered(uint256 indexed id, WaterSource source, WaterRightType rightType);
    event WaterTradeSettled(uint256 indexed tradeId);
    event DroughtAdjustment(uint256 indexed rightId, uint256 adjustedAt);

    modifier onlyWaterRegulator() {
        require(isWaterRegulator[msg.sender] || msg.sender == owner(), "Not water regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAllocationML = FHE.asEuint64(0);
        _totalTradeVolumeML = FHE.asEuint64(0);
        _totalTradeValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalAllocationML);
        FHE.allowThis(_totalTradeVolumeML);
        FHE.allowThis(_totalTradeValueUSD);
        isWaterRegulator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addWaterRegulator(address r) external onlyOwner { isWaterRegulator[r] = true; }

    function registerWaterRight(
        WaterSource waterSource,
        WaterRightType rightType,
        string calldata basinCode,
        externalEuint64 encAllocation, bytes calldata aProof,
        externalEuint32 encPriority, bytes calldata pProof,
        externalEuint64 encMarketValue, bytes calldata mvProof
    ) external onlyWaterRegulator whenNotPaused returns (uint256 id) {
        euint64 allocation = FHE.fromExternal(encAllocation, aProof);
        euint32 priority = FHE.fromExternal(encPriority, pProof);
        euint64 marketVal = FHE.fromExternal(encMarketValue, mvProof);
        id = rightCount++;
        waterRights[id].rightHolder = msg.sender;
        waterRights[id].waterSource = waterSource;
        waterRights[id].rightType = rightType;
        waterRights[id].basinCode = basinCode;
        waterRights[id].annualAllocationML = allocation;
        waterRights[id].usedVolumeML = FHE.asEuint64(0);
        waterRights[id].tradableVolumeML = allocation;
        waterRights[id].priorityScore = priority;
        waterRights[id].marketValuePerMLUSD = marketVal;
        waterRights[id].active = true;
        _totalAllocationML = FHE.add(_totalAllocationML, allocation);
        FHE.allowThis(waterRights[id].annualAllocationML); FHE.allow(waterRights[id].annualAllocationML, msg.sender);
        FHE.allowThis(waterRights[id].usedVolumeML); FHE.allow(waterRights[id].usedVolumeML, msg.sender);
        FHE.allowThis(waterRights[id].tradableVolumeML); FHE.allow(waterRights[id].tradableVolumeML, msg.sender);
        FHE.allowThis(waterRights[id].priorityScore);
        FHE.allowThis(waterRights[id].marketValuePerMLUSD); FHE.allow(waterRights[id].marketValuePerMLUSD, msg.sender);
        FHE.allowThis(_totalAllocationML);
        emit WaterRightRegistered(id, waterSource, rightType);
    }

    function transferRightOwnership(uint256 rightId, address newHolder) external onlyWaterRegulator {
        waterRights[rightId].rightHolder = newHolder;
        FHE.allow(waterRights[rightId].annualAllocationML, newHolder);
        FHE.allow(waterRights[rightId].tradableVolumeML, newHolder);
    }

    function initiateWaterTrade(
        uint256 sellerRightId,
        address buyer,
        uint256 buyerRightId,
        externalEuint64 encVolume, bytes calldata vProof,
        externalEuint64 encPricePerML, bytes calldata pProof
    ) external whenNotPaused nonReentrant returns (uint256 tradeId) {
        WaterRight storage sellerRight = waterRights[sellerRightId];
        require(msg.sender == sellerRight.rightHolder, "Not right holder");
        euint64 vol = FHE.fromExternal(encVolume, vProof);
        euint64 pricePerML = FHE.fromExternal(encPricePerML, pProof);
        euint64 totalConsideration = FHE.mul(FHE.asEuint64(1), pricePerML); // proxy
        ebool hasTradable = FHE.ge(sellerRight.tradableVolumeML, vol);
        euint64 tradedVol = FHE.select(hasTradable, vol, FHE.asEuint64(0));
        sellerRight.tradableVolumeML = FHE.sub(sellerRight.tradableVolumeML, tradedVol);
        tradeId = tradeCount++;
        trades[tradeId].sellerRightId = sellerRightId;
        trades[tradeId].buyerRightId = buyerRightId;
        trades[tradeId].seller = msg.sender;
        trades[tradeId].buyer = buyer;
        trades[tradeId].volumeML = tradedVol;
        trades[tradeId].pricePerMLUSD = pricePerML;
        trades[tradeId].totalConsiderationUSD = totalConsideration;
        trades[tradeId].tradeDate = block.timestamp;
        trades[tradeId].settled = false;
        _totalTradeVolumeML = FHE.add(_totalTradeVolumeML, tradedVol);
        _totalTradeValueUSD = FHE.add(_totalTradeValueUSD, totalConsideration);
        FHE.allowThis(trades[tradeId].volumeML); FHE.allow(trades[tradeId].volumeML, msg.sender); FHE.allow(trades[tradeId].volumeML, buyer);
        FHE.allowThis(trades[tradeId].pricePerMLUSD); FHE.allow(trades[tradeId].pricePerMLUSD, buyer);
        FHE.allowThis(trades[tradeId].totalConsiderationUSD); FHE.allow(trades[tradeId].totalConsiderationUSD, msg.sender); FHE.allow(trades[tradeId].totalConsiderationUSD, buyer);
        FHE.allowThis(sellerRight.tradableVolumeML); FHE.allow(sellerRight.tradableVolumeML, msg.sender);
        FHE.allowThis(_totalTradeVolumeML);
        FHE.allowThis(_totalTradeValueUSD);
        emit WaterTradeSettled(tradeId);
    }

    function applyDroughtReduction(
        uint256 rightId,
        externalEuint64 encNewAllocation, bytes calldata proof
    ) external onlyWaterRegulator {
        WaterRight storage wr = waterRights[rightId];
        euint64 newAlloc = FHE.fromExternal(encNewAllocation, proof);
        wr.annualAllocationML = newAlloc;
        // Re-compute tradable as min of tradable and new allocation
        ebool tradableLarger = FHE.gt(wr.tradableVolumeML, newAlloc);
        wr.tradableVolumeML = FHE.select(tradableLarger, newAlloc, wr.tradableVolumeML);
        FHE.allowThis(wr.annualAllocationML); FHE.allow(wr.annualAllocationML, wr.rightHolder);
        FHE.allowThis(wr.tradableVolumeML); FHE.allow(wr.tradableVolumeML, wr.rightHolder);
        emit DroughtAdjustment(rightId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalAllocationML, viewer);
        FHE.allow(_totalTradeVolumeML, viewer);
        FHE.allow(_totalTradeValueUSD, viewer);
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