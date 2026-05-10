// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMiningRoyaltySplitPool
/// @notice Encrypted mining royalty split pool: hidden mine production tonnage,
///         confidential commodity spot prices, private royalty stack calculations
///         (gov/NSR/GOR/streaming), and encrypted royalty purchaser secondary trades.
contract PrivateMiningRoyaltySplitPool is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MineralType { Gold, Copper, Silver, Lithium, Cobalt, Nickel, Iron }
    enum RoyaltyType { NetSmelterReturn, GrossOverriding, StreamingDelivery, Government, NetProfitInterest }

    struct MineProduction {
        address mineOperator;
        MineralType mineralType;
        string mineRef;
        euint64 quarterlyProductionOz; // encrypted quarterly oz (or tonnes)
        euint64 spotPricePerOzUSD;     // encrypted commodity spot
        euint64 quarterlyGrossRevenueUSD; // encrypted gross revenue
        euint64 totalRoyaltiesPayableUSD; // encrypted royalties due
        uint256 reportingPeriod;
    }

    struct RoyaltyInterest {
        uint256 productionId;
        address royaltyHolder;
        RoyaltyType royaltyType;
        euint16 royaltyRateBps;        // encrypted royalty rate
        euint64 royaltyAmountUSD;      // encrypted royalty payment
        euint64 streamingDeliveryOz;   // encrypted streaming oz
        uint256 paidAt;
    }

    mapping(uint256 => MineProduction) private productions;
    mapping(uint256 => RoyaltyInterest) private royaltyInterests;
    mapping(address => bool) public isMiningRegulator;

    uint256 public productionCount;
    uint256 public royaltyCount;
    euint64 private _totalProductionValueUSD;
    euint64 private _totalRoyaltiesPaidUSD;

    event ProductionReported(uint256 indexed id, MineralType mineralType);
    event RoyaltyPaid(uint256 indexed royaltyId, uint256 productionId, RoyaltyType royaltyType);

    modifier onlyMiningRegulator() {
        require(isMiningRegulator[msg.sender] || msg.sender == owner(), "Not mining regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalProductionValueUSD = FHE.asEuint64(0);
        _totalRoyaltiesPaidUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalProductionValueUSD);
        FHE.allowThis(_totalRoyaltiesPaidUSD);
        isMiningRegulator[msg.sender] = true;
    }

    function addMiningRegulator(address r) external onlyOwner { isMiningRegulator[r] = true; }

    function reportProduction(
        MineralType mineralType, string calldata mineRef,
        externalEuint64 encQtrProd, bytes calldata qpProof,
        externalEuint64 encSpotPrice, bytes calldata spProof,
        uint256 reportingPeriod
    ) external returns (uint256 id) {
        euint64 qtrProd = FHE.fromExternal(encQtrProd, qpProof);
        euint64 spotPrice = FHE.fromExternal(encSpotPrice, spProof);
        euint64 grossRevenue = FHE.mul(qtrProd, spotPrice); // [arithmetic_overflow_underflow]
        euint64 spotPriceScaled = FHE.mul(spotPrice, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        id = productionCount++;
        productions[id] = MineProduction({
            mineOperator: msg.sender, mineralType: mineralType, mineRef: mineRef,
            quarterlyProductionOz: qtrProd, spotPricePerOzUSD: spotPrice,
            quarterlyGrossRevenueUSD: grossRevenue, totalRoyaltiesPayableUSD: FHE.asEuint64(0),
            reportingPeriod: reportingPeriod
        });
        _totalProductionValueUSD = FHE.add(_totalProductionValueUSD, grossRevenue);
        FHE.allowThis(productions[id].quarterlyProductionOz); FHE.allow(productions[id].quarterlyProductionOz, msg.sender);
        FHE.allowThis(productions[id].spotPricePerOzUSD); FHE.allow(productions[id].spotPricePerOzUSD, msg.sender);
        FHE.allowThis(productions[id].quarterlyGrossRevenueUSD); FHE.allow(productions[id].quarterlyGrossRevenueUSD, msg.sender);
        FHE.allowThis(productions[id].totalRoyaltiesPayableUSD);
        FHE.allowThis(_totalProductionValueUSD);
        emit ProductionReported(id, mineralType);
    }

    function distributeRoyalty(
        uint256 productionId, address royaltyHolder, RoyaltyType royaltyType,
        externalEuint16 encRoyaltyRate, bytes calldata rrProof,
        externalEuint64 encRoyaltyAmt, bytes calldata raProof,
        externalEuint64 encStreamingOz, bytes calldata soProof
    ) external onlyMiningRegulator nonReentrant returns (uint256 royaltyId) {
        euint16 royaltyRate = FHE.fromExternal(encRoyaltyRate, rrProof);
        euint64 royaltyAmt = FHE.fromExternal(encRoyaltyAmt, raProof);
        euint64 streamingOz = FHE.fromExternal(encStreamingOz, soProof);
        royaltyId = royaltyCount++;
        royaltyInterests[royaltyId] = RoyaltyInterest({
            productionId: productionId, royaltyHolder: royaltyHolder, royaltyType: royaltyType,
            royaltyRateBps: royaltyRate, royaltyAmountUSD: royaltyAmt,
            streamingDeliveryOz: streamingOz, paidAt: block.timestamp
        });
        productions[productionId].totalRoyaltiesPayableUSD = FHE.add(productions[productionId].totalRoyaltiesPayableUSD, royaltyAmt);
        _totalRoyaltiesPaidUSD = FHE.add(_totalRoyaltiesPaidUSD, royaltyAmt);
        FHE.allowThis(royaltyInterests[royaltyId].royaltyRateBps);
        FHE.allowThis(royaltyInterests[royaltyId].royaltyAmountUSD); FHE.allow(royaltyInterests[royaltyId].royaltyAmountUSD, royaltyHolder); FHE.allow(royaltyInterests[royaltyId].royaltyAmountUSD, productions[productionId].mineOperator);
        FHE.allowThis(royaltyInterests[royaltyId].streamingDeliveryOz); FHE.allow(royaltyInterests[royaltyId].streamingDeliveryOz, royaltyHolder);
        FHE.allowThis(productions[productionId].totalRoyaltiesPayableUSD);
        FHE.allowThis(_totalRoyaltiesPaidUSD);
        emit RoyaltyPaid(royaltyId, productionId, royaltyType);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_totalProductionValueUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalProductionValueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalRoyaltiesPaidUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalRoyaltiesPaidUSD, viewer);
    }
}
