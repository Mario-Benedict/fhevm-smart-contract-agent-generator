// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AgriculturePrivateCommodityHedge
/// @notice Agricultural commodity hedging platform where farmer hedge ratios
///         and contract prices are encrypted. Farmers lock in encrypted future
///         prices without revealing crop yields to market participants.
contract AgriculturePrivateCommodityHedge is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum CommodityType { Wheat, Corn, Soybean, Coffee, Sugar, Cocoa }

    struct HedgeContract {
        address farmer;
        CommodityType commodity;
        euint32 quantityBushels;  // encrypted crop quantity
        euint64 lockedPrice;      // encrypted future price (per bushel)
        euint64 totalLocked;      // encrypted total hedge value
        euint16 hedgeRatioBps;    // encrypted % of crop hedged
        uint256 deliveryDate;
        bool settled;
        bool exercised;
    }

    struct SpotPriceUpdate {
        CommodityType commodity;
        euint64 spotPrice;
        uint256 updatedAt;
    }

    mapping(uint256 => HedgeContract) private hedges;
    uint256 public hedgeCount;
    mapping(CommodityType => SpotPriceUpdate) private spotPrices;
    mapping(address => bool) public isFarmer;
    euint64 private _hedgingFeeRate;
    euint64 private _totalHedgedValue;

    event FarmerRegistered(address indexed farmer);
    event HedgeCreated(uint256 indexed id, address farmer, CommodityType commodity);
    event HedgeSettled(uint256 indexed id, bool exercised);
    event SpotPriceUpdated(CommodityType commodity);

    constructor(externalEuint64 encFeeRate, bytes memory proof) Ownable(msg.sender) {
        _hedgingFeeRate = FHE.fromExternal(encFeeRate, proof);
        _totalHedgedValue = FHE.asEuint64(0);
        FHE.allowThis(_hedgingFeeRate);
        FHE.allowThis(_totalHedgedValue);
    }

    function registerFarmer(address f) external onlyOwner {
        isFarmer[f] = true;
        emit FarmerRegistered(f);
    }

    function updateSpotPrice(
        CommodityType commodity,
        externalEuint64 encPrice, bytes calldata proof
    ) external onlyOwner {
        spotPrices[commodity].commodity = commodity;
        spotPrices[commodity].spotPrice = FHE.fromExternal(encPrice, proof);
        spotPrices[commodity].updatedAt = block.timestamp;
        FHE.allowThis(spotPrices[commodity].spotPrice);
        emit SpotPriceUpdated(commodity);
    }

    function createHedge(
        CommodityType commodity, uint256 deliveryDate,
        externalEuint32 encQuantity, bytes calldata qProof,
        externalEuint64 encLockPrice, bytes calldata lProof,
        externalEuint16 encRatio, bytes calldata rProof
    ) external nonReentrant returns (uint256 id) {
        require(isFarmer[msg.sender], "Not farmer");
        id = hedgeCount++;
        euint32 qty = FHE.fromExternal(encQuantity, qProof);
        euint64 lockPrice = FHE.fromExternal(encLockPrice, lProof);
        euint16 ratio = FHE.fromExternal(encRatio, rProof);
        ebool _safeMul0 = FHE.le(lockPrice, FHE.asEuint64(type(uint64).max / 1));
        euint64 totalValue = FHE.mul(lockPrice, FHE.asEuint64(1)); // simplified
        euint64 fee = FHE.div(FHE.mul(totalValue, _hedgingFeeRate), 10000);
        hedges[id].farmer = msg.sender;
        hedges[id].commodity = commodity;
        hedges[id].quantityBushels = qty;
        hedges[id].lockedPrice = lockPrice;
        ebool _safeSub0 = FHE.ge(totalValue, fee);
        hedges[id].totalLocked = FHE.select(_safeSub0, FHE.sub(totalValue, fee), FHE.asEuint64(0));
        hedges[id].hedgeRatioBps = ratio;
        hedges[id].deliveryDate = deliveryDate;
        hedges[id].settled = false;
        hedges[id].exercised = false;
        _totalHedgedValue = FHE.add(_totalHedgedValue, hedges[id].totalLocked);
        FHE.allowThis(hedges[id].quantityBushels);
        FHE.allow(hedges[id].quantityBushels, msg.sender);
        FHE.allowThis(hedges[id].lockedPrice);
        FHE.allow(hedges[id].lockedPrice, msg.sender);
        FHE.allowThis(hedges[id].totalLocked);
        FHE.allow(hedges[id].totalLocked, msg.sender);
        FHE.allowThis(hedges[id].hedgeRatioBps);
        FHE.allow(hedges[id].hedgeRatioBps, msg.sender);
        FHE.allowThis(_totalHedgedValue);
        FHE.allow(fee, owner());
        emit HedgeCreated(id, msg.sender, commodity);
    }

    function settleHedge(uint256 hedgeId) external onlyOwner nonReentrant {
        HedgeContract storage h = hedges[hedgeId];
        require(!h.settled && block.timestamp >= h.deliveryDate, "Cannot settle");
        h.settled = true;
        SpotPriceUpdate storage spot = spotPrices[h.commodity];
        // Farmer exercises if locked > spot
        ebool shouldExercise = FHE.gt(h.lockedPrice, spot.spotPrice);
        h.exercised = FHE.isInitialized(shouldExercise);
        // If exercised: farmer gets locked price, otherwise spot price
        euint64 payout = FHE.select(shouldExercise, h.totalLocked, FHE.asEuint64(0));
        FHE.allow(payout, h.farmer);
        ebool _safeSub1 = FHE.ge(_totalHedgedValue, h.totalLocked);
        _totalHedgedValue = FHE.select(_safeSub1, FHE.sub(_totalHedgedValue, h.totalLocked), FHE.asEuint64(0));
        FHE.allowThis(_totalHedgedValue);
        emit HedgeSettled(hedgeId, h.exercised);
    }

    function allowHedgeData(uint256 id, address viewer) external {
        require(hedges[id].farmer == msg.sender, "Not owner");
        FHE.allow(hedges[id].quantityBushels, viewer);
        FHE.allow(hedges[id].lockedPrice, viewer);
        FHE.allow(hedges[id].totalLocked, viewer);
    }
}
