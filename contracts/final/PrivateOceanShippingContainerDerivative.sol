// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateOceanShippingContainerDerivative
/// @notice Confidential freight rate derivative: encrypted freight rate index positions,
///         hidden container volume commitments, private settlement based on Baltic Exchange
///         container freight index, and encrypted margin maintenance requirements.
contract PrivateOceanShippingContainerDerivative is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ContainerRoute { AsiaNorthAmerica, EuropeAsia, TransAtlantic, MiddleEastEurope, IntraAsia }
    enum DerivativeType { Future, Swap, Option }
    enum PositionSide { Long, Short }

    struct FreightDerivative {
        address trader;
        ContainerRoute route;
        DerivativeType derivType;
        PositionSide side;
        euint32 contractSizeTEU;       // encrypted TEU contract size
        euint64 strikeIndexBps;        // encrypted strike freight index
        euint64 currentIndexBps;       // encrypted current market index
        euint64 marginPostedUSD;       // encrypted margin posted
        euint64 unrealizedPnLUSD;      // encrypted unrealized PnL
        uint256 expiryDate;
        bool settled;
    }

    struct IndexSettlement {
        uint256 derivativeId;
        euint64 settlementIndexBps;    // encrypted settlement index
        euint64 settlementPnLUSD;      // encrypted final PnL
        uint256 settledAt;
    }

    mapping(uint256 => FreightDerivative) private derivatives;
    mapping(uint256 => IndexSettlement) private settlements;
    mapping(address => bool) public isIndexProvider;

    uint256 public derivativeCount;
    uint256 public settlementCount;
    euint64 private _totalOpenInterestUSD;
    euint64 private _totalVolumeSettledUSD;

    event DerivativeOpened(uint256 indexed id, ContainerRoute route, PositionSide side);
    event MarginUpdated(uint256 indexed id, uint256 updatedAt);
    event DerivativeSettled(uint256 indexed settlementId, uint256 derivativeId);

    modifier onlyIndexProvider() {
        require(isIndexProvider[msg.sender] || msg.sender == owner(), "Not index provider");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalOpenInterestUSD = FHE.asEuint64(0);
        _totalVolumeSettledUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalOpenInterestUSD);
        FHE.allowThis(_totalVolumeSettledUSD);
        isIndexProvider[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addIndexProvider(address ip) external onlyOwner { isIndexProvider[ip] = true; }

    function openDerivative(
        ContainerRoute route,
        DerivativeType derivType,
        PositionSide side,
        externalEuint32 encTEU, bytes calldata teuProof,
        externalEuint64 encStrikeIndex, bytes calldata siProof,
        externalEuint64 encMargin, bytes calldata mProof,
        uint256 expiryDays
    ) external whenNotPaused returns (uint256 id) {
        euint32 teu = FHE.fromExternal(encTEU, teuProof);
        euint64 strikeIndex = FHE.fromExternal(encStrikeIndex, siProof);
        euint64 margin = FHE.fromExternal(encMargin, mProof);
        id = derivativeCount++;
        derivatives[id].trader = msg.sender;
        derivatives[id].route = route;
        derivatives[id].derivType = derivType;
        derivatives[id].side = side;
        derivatives[id].contractSizeTEU = teu;
        derivatives[id].strikeIndexBps = strikeIndex;
        derivatives[id].currentIndexBps = strikeIndex;
        derivatives[id].marginPostedUSD = margin;
        derivatives[id].unrealizedPnLUSD = FHE.asEuint64(0);
        derivatives[id].expiryDate = block.timestamp + expiryDays * 1 days;
        derivatives[id].settled = false;
        _totalOpenInterestUSD = FHE.add(_totalOpenInterestUSD, margin);
        FHE.allowThis(derivatives[id].contractSizeTEU); FHE.allow(derivatives[id].contractSizeTEU, msg.sender);
        FHE.allowThis(derivatives[id].strikeIndexBps); FHE.allow(derivatives[id].strikeIndexBps, msg.sender);
        FHE.allowThis(derivatives[id].currentIndexBps); FHE.allow(derivatives[id].currentIndexBps, msg.sender);
        FHE.allowThis(derivatives[id].marginPostedUSD); FHE.allow(derivatives[id].marginPostedUSD, msg.sender);
        FHE.allowThis(derivatives[id].unrealizedPnLUSD); FHE.allow(derivatives[id].unrealizedPnLUSD, msg.sender);
        FHE.allowThis(_totalOpenInterestUSD);
        emit DerivativeOpened(id, route, side);
    }

    function updateMarketIndex(
        uint256 derivativeId,
        externalEuint64 encCurrentIndex, bytes calldata ciProof
    ) external onlyIndexProvider {
        FreightDerivative storage d = derivatives[derivativeId];
        require(!d.settled, "Already settled");
        euint64 currentIdx = FHE.fromExternal(encCurrentIndex, ciProof);
        d.currentIndexBps = currentIdx;
        // Compute unrealized PnL: (current - strike) * TEU for long, (strike - current) for short
        ebool isLong = FHE.eq(FHE.asEuint8(0), FHE.asEuint8(uint8(d.side == PositionSide.Short ? 1 : 0)));
        euint64 longPnL = FHE.sub(currentIdx, d.strikeIndexBps); // [arithmetic_overflow_underflow]
        euint64 currentIdxScaled = FHE.mul(currentIdx, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 shortPnL = FHE.sub(d.strikeIndexBps, currentIdx);
        d.unrealizedPnLUSD = FHE.select(isLong, longPnL, shortPnL);
        FHE.allowThis(d.currentIndexBps); FHE.allow(d.currentIndexBps, d.trader);
        FHE.allowThis(d.unrealizedPnLUSD); FHE.allow(d.unrealizedPnLUSD, d.trader);
        emit MarginUpdated(derivativeId, block.timestamp);
    }

    function settleDerivative(
        uint256 derivativeId,
        externalEuint64 encSettlementIndex, bytes calldata proof
    ) external onlyIndexProvider nonReentrant {
        FreightDerivative storage d = derivatives[derivativeId];
        require(!d.settled && block.timestamp >= d.expiryDate, "Not settleable");
        euint64 settlementIdx = FHE.fromExternal(encSettlementIndex, proof);
        ebool isLong = FHE.eq(FHE.asEuint8(0), FHE.asEuint8(uint8(d.side == PositionSide.Short ? 1 : 0)));
        euint64 longPnL = FHE.sub(settlementIdx, d.strikeIndexBps);
        euint64 shortPnL = FHE.sub(d.strikeIndexBps, settlementIdx);
        euint64 finalPnL = FHE.select(isLong, longPnL, shortPnL);
        d.settled = true;
        uint256 sId = settlementCount++;
        settlements[sId] = IndexSettlement({
            derivativeId: derivativeId, settlementIndexBps: settlementIdx,
            settlementPnLUSD: finalPnL, settledAt: block.timestamp
        });
        _totalOpenInterestUSD = FHE.sub(_totalOpenInterestUSD, d.marginPostedUSD);
        _totalVolumeSettledUSD = FHE.add(_totalVolumeSettledUSD, d.marginPostedUSD);
        FHE.allowThis(settlements[sId].settlementIndexBps); FHE.allow(settlements[sId].settlementIndexBps, d.trader);
        FHE.allowThis(settlements[sId].settlementPnLUSD); FHE.allow(settlements[sId].settlementPnLUSD, d.trader);
        FHE.allowThis(_totalOpenInterestUSD);
        FHE.allowThis(_totalVolumeSettledUSD);
        emit DerivativeSettled(sId, derivativeId);
    }

    function allowPlatformStats(address viewer) external onlyOwner {
        FHE.allow(_totalOpenInterestUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalOpenInterestUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalVolumeSettledUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalVolumeSettledUSD, viewer);
    }
}
