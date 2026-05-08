// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateWaterRightsAllocationSystem
/// @notice Water rights marketplace with encrypted allocation volumes,
///         usage compliance, and trading prices for agricultural and municipal users.
contract PrivateWaterRightsAllocationSystem is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum WaterSource { GROUNDWATER, SURFACE_WATER, RECYCLED, DESALINATED, RESERVOIR }
    enum UserType { AGRICULTURAL, MUNICIPAL, INDUSTRIAL, ENVIRONMENTAL_FLOW }

    struct WaterRight {
        string permitId;
        address rightHolder;
        WaterSource source;
        UserType userType;
        euint64 annualAllocationML;    // encrypted megaliters allocated
        euint64 usedThisSeasonML;      // encrypted seasonal usage
        euint64 availableBalance;      // encrypted remaining balance
        euint64 marketValueUSD;        // encrypted tradeable value
        euint8  complianceScore;       // encrypted usage compliance 0-100
        euint8  waterQualityScore;     // encrypted quality 0-100
        uint256 permitExpiry;
        bool tradeable;
        bool suspended;
    }

    struct WaterTrade {
        uint256 fromRightId;
        uint256 toRightId;
        address seller;
        address buyer;
        euint64 volumeML;              // encrypted traded volume
        euint64 pricePerMLUSD;        // encrypted price
        euint64 totalPriceUSD;        // encrypted total value
        bool settled;
    }

    mapping(uint256 => WaterRight) private rights;
    mapping(uint256 => WaterTrade) private trades;
    mapping(address => bool) public isWaterAuthority;
    uint256 public rightCount;
    uint256 public tradeCount;
    euint64 private _totalAllocatedML;
    euint64 private _totalTradedVolume;
    euint64 private _totalTradeValue;

    event RightGranted(uint256 indexed rightId, WaterSource source);
    event UsageRecorded(uint256 indexed rightId);
    event TradeExecuted(uint256 indexed tradeId);
    event RightSuspended(uint256 indexed rightId);

    constructor() Ownable(msg.sender) {
        _totalAllocatedML = FHE.asEuint64(0);
        _totalTradedVolume = FHE.asEuint64(0);
        _totalTradeValue = FHE.asEuint64(0);
        FHE.allowThis(_totalAllocatedML);
        FHE.allowThis(_totalTradedVolume);
        FHE.allowThis(_totalTradeValue);
        isWaterAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isWaterAuthority[a] = true; }

    function grantWaterRight(
        string calldata permitId, address rightHolder,
        WaterSource source, UserType uType,
        externalEuint64 encAllocation, bytes calldata allocProof,
        externalEuint64 encValue,      bytes calldata valueProof,
        externalEuint8  encQuality,    bytes calldata qualProof,
        uint256 permitExpiry
    ) external returns (uint256 rightId) {
        require(isWaterAuthority[msg.sender], "Not authority");
        euint64 allocation = FHE.fromExternal(encAllocation, allocProof);
        euint64 value      = FHE.fromExternal(encValue, valueProof);
        euint8  quality    = FHE.fromExternal(encQuality, qualProof);
        rightId = rightCount++;
        rights[rightId] = WaterRight({
            permitId: permitId, rightHolder: rightHolder,
            source: source, userType: uType,
            annualAllocationML: allocation, usedThisSeasonML: FHE.asEuint64(0),
            availableBalance: allocation, marketValueUSD: value,
            complianceScore: FHE.asEuint8(100), waterQualityScore: quality,
            permitExpiry: permitExpiry, tradeable: true, suspended: false
        });
        _totalAllocatedML = FHE.add(_totalAllocatedML, allocation);
        FHE.allowThis(rights[rightId].annualAllocationML);
        FHE.allow(rights[rightId].annualAllocationML, rightHolder);
        FHE.allowThis(rights[rightId].usedThisSeasonML);
        FHE.allow(rights[rightId].usedThisSeasonML, rightHolder);
        FHE.allowThis(rights[rightId].availableBalance);
        FHE.allow(rights[rightId].availableBalance, rightHolder);
        FHE.allowThis(rights[rightId].marketValueUSD);
        FHE.allow(rights[rightId].marketValueUSD, rightHolder);
        FHE.allowThis(rights[rightId].complianceScore);
        FHE.allow(rights[rightId].complianceScore, rightHolder);
        FHE.allowThis(rights[rightId].waterQualityScore);
        FHE.allowThis(_totalAllocatedML);
        emit RightGranted(rightId, source);
    }

    function recordUsage(uint256 rightId, externalEuint64 encUsage, bytes calldata proof) external {
        require(rights[rightId].rightHolder == msg.sender || isWaterAuthority[msg.sender], "Unauthorized");
        euint64 usage = FHE.fromExternal(encUsage, proof);
        rights[rightId].usedThisSeasonML = FHE.add(rights[rightId].usedThisSeasonML, usage);
        rights[rightId].availableBalance = FHE.sub(rights[rightId].annualAllocationML, rights[rightId].usedThisSeasonML);
        // Check compliance: update score based on whether usage exceeds allocation
        ebool overAllocated = FHE.gt(rights[rightId].usedThisSeasonML, rights[rightId].annualAllocationML);
        rights[rightId].complianceScore = FHE.select(overAllocated, FHE.asEuint8(0), FHE.asEuint8(100));
        FHE.allowThis(rights[rightId].usedThisSeasonML);
        FHE.allowThis(rights[rightId].availableBalance);
        FHE.allowThis(rights[rightId].complianceScore);
        emit UsageRecorded(rightId);
    }

    function executeTrade(
        uint256 fromRightId,
        uint256 toRightId,
        address buyer,
        externalEuint64 encVolume, bytes calldata volProof,
        externalEuint64 encPrice,  bytes calldata priceProof
    ) external nonReentrant returns (uint256 tradeId) {
        require(rights[fromRightId].rightHolder == msg.sender, "Not right holder");
        require(rights[fromRightId].tradeable && !rights[fromRightId].suspended, "Not tradeable");
        euint64 volume = FHE.fromExternal(encVolume, volProof);
        euint64 price  = FHE.fromExternal(encPrice, priceProof);
        euint64 total  = FHE.mul(volume, price);
        rights[fromRightId].availableBalance = FHE.sub(rights[fromRightId].availableBalance, volume);
        rights[toRightId].availableBalance = FHE.add(rights[toRightId].availableBalance, volume);
        tradeId = tradeCount++;
        trades[tradeId] = WaterTrade({
            fromRightId: fromRightId, toRightId: toRightId,
            seller: msg.sender, buyer: buyer,
            volumeML: volume, pricePerMLUSD: price,
            totalPriceUSD: total, settled: true
        });
        _totalTradedVolume = FHE.add(_totalTradedVolume, volume);
        _totalTradeValue = FHE.add(_totalTradeValue, total);
        FHE.allowThis(rights[fromRightId].availableBalance);
        FHE.allowThis(rights[toRightId].availableBalance);
        FHE.allowThis(trades[tradeId].volumeML);
        FHE.allow(trades[tradeId].volumeML, buyer);
        FHE.allow(trades[tradeId].volumeML, msg.sender);
        FHE.allowThis(trades[tradeId].totalPriceUSD);
        FHE.allow(trades[tradeId].totalPriceUSD, msg.sender);
        FHE.allowThis(_totalTradedVolume);
        FHE.allowThis(_totalTradeValue);
        emit TradeExecuted(tradeId);
    }

    function suspendRight(uint256 rightId) external {
        require(isWaterAuthority[msg.sender], "Not authority");
        rights[rightId].suspended = true;
        emit RightSuspended(rightId);
    }

    function allowSystemView(address viewer) external onlyOwner {
        FHE.allow(_totalAllocatedML, viewer);
        FHE.allow(_totalTradedVolume, viewer);
        FHE.allow(_totalTradeValue, viewer);
    }
}
