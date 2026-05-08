// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateElectricGridBatteryStorageAuction
/// @notice Encrypted grid-scale battery storage capacity auction: hidden storage
///         capacity bids, confidential round-trip efficiency specs, private
///         frequency regulation revenue estimates, and encrypted capacity payment
///         settlements.
contract PrivateElectricGridBatteryStorageAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum StorageTechnology { LithiumNMC, LithiumLFP, VanadiumFlow, ZincBromine, SodiumSulfur }
    enum ServiceType { FrequencyRegulation, PeakShaving, ReserveCapacity, EnergyArbitrage }

    struct StorageBid {
        address storageOperator;
        StorageTechnology technology;
        ServiceType serviceType;
        euint32 capacityMWh;           // encrypted capacity bid
        euint32 powerRatingMW;         // encrypted power rating
        euint16 roundTripEffBps;       // encrypted round-trip efficiency
        euint64 capacityPricePerMWhUSD;// encrypted bid price per MWh
        euint64 totalCapacityPaymentUSD; // encrypted total payment
        euint16 degradationRateBps;    // encrypted annual degradation
        bool accepted;
        uint256 submittedAt;
    }

    struct CapacityPeriodSettlement {
        uint256 bidId;
        euint64 settledCapacityMWh;    // encrypted settled capacity
        euint64 performanceBonusUSD;   // encrypted performance bonus
        euint64 penaltyDeductionUSD;   // encrypted underperformance penalty
        euint64 netPaymentUSD;         // encrypted net payment
        uint256 periodStart;
        uint256 periodEnd;
    }

    mapping(uint256 => StorageBid) private bids;
    mapping(uint256 => CapacityPeriodSettlement) private settlements;
    mapping(address => bool) public isGridOperator;

    uint256 public bidCount;
    uint256 public settlementCount;
    euint64 private _totalCapacityCommittedMWh;
    euint64 private _totalCapacityPaymentsUSD;

    event StorageBidSubmitted(uint256 indexed id, StorageTechnology tech, ServiceType service);
    event BidAccepted(uint256 indexed id, address operator);
    event PeriodSettled(uint256 indexed settlementId, uint256 bidId);

    modifier onlyGridOperator() {
        require(isGridOperator[msg.sender] || msg.sender == owner(), "Not grid operator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCapacityCommittedMWh = FHE.asEuint64(0);
        _totalCapacityPaymentsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalCapacityCommittedMWh);
        FHE.allowThis(_totalCapacityPaymentsUSD);
        isGridOperator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addGridOperator(address op) external onlyOwner { isGridOperator[op] = true; }

    function submitStorageBid(
        StorageTechnology technology, ServiceType serviceType,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint32 encPower, bytes calldata powProof,
        externalEuint16 encEfficiency, bytes calldata effProof,
        externalEuint64 encCapPrice, bytes calldata cpProof,
        externalEuint16 encDegradation, bytes calldata degProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 cap = FHE.fromExternal(encCapacity, capProof);
        euint32 power = FHE.fromExternal(encPower, powProof);
        euint16 eff = FHE.fromExternal(encEfficiency, effProof);
        euint64 capPrice = FHE.fromExternal(encCapPrice, cpProof);
        euint16 deg = FHE.fromExternal(encDegradation, degProof);
        euint64 totalPay = FHE.mul(FHE.asEuint64(1), capPrice);
        id = bidCount++;
        bids[id] = StorageBid({
            storageOperator: msg.sender, technology: technology, serviceType: serviceType,
            capacityMWh: cap, powerRatingMW: power, roundTripEffBps: eff,
            capacityPricePerMWhUSD: capPrice, totalCapacityPaymentUSD: totalPay,
            degradationRateBps: deg, accepted: false, submittedAt: block.timestamp
        });
        FHE.allowThis(bids[id].capacityMWh); FHE.allow(bids[id].capacityMWh, msg.sender);
        FHE.allowThis(bids[id].powerRatingMW); FHE.allow(bids[id].powerRatingMW, msg.sender);
        FHE.allowThis(bids[id].roundTripEffBps); FHE.allow(bids[id].roundTripEffBps, msg.sender);
        FHE.allowThis(bids[id].capacityPricePerMWhUSD); FHE.allow(bids[id].capacityPricePerMWhUSD, msg.sender);
        FHE.allowThis(bids[id].totalCapacityPaymentUSD); FHE.allow(bids[id].totalCapacityPaymentUSD, msg.sender);
        FHE.allowThis(bids[id].degradationRateBps);
        emit StorageBidSubmitted(id, technology, serviceType);
    }

    function acceptStorageBid(uint256 bidId) external onlyGridOperator {
        StorageBid storage b = bids[bidId];
        require(!b.accepted, "Already accepted");
        b.accepted = true;
        _totalCapacityCommittedMWh = FHE.add(_totalCapacityCommittedMWh, FHE.asEuint64(1));
        _totalCapacityPaymentsUSD = FHE.add(_totalCapacityPaymentsUSD, b.totalCapacityPaymentUSD);
        FHE.allow(b.capacityMWh, msg.sender);
        FHE.allowThis(_totalCapacityCommittedMWh);
        FHE.allowThis(_totalCapacityPaymentsUSD);
        emit BidAccepted(bidId, b.storageOperator);
    }

    function settleCapacityPeriod(
        uint256 bidId,
        externalEuint64 encSettledCap, bytes calldata scProof,
        externalEuint64 encPerfBonus, bytes calldata pbProof,
        externalEuint64 encPenalty, bytes calldata penProof,
        uint256 periodStart, uint256 periodEnd
    ) external onlyGridOperator nonReentrant returns (uint256 sId) {
        StorageBid storage b = bids[bidId];
        require(b.accepted, "Bid not accepted");
        euint64 settledCap = FHE.fromExternal(encSettledCap, scProof);
        euint64 perfBonus = FHE.fromExternal(encPerfBonus, pbProof);
        euint64 penalty = FHE.fromExternal(encPenalty, penProof);
        euint64 netPayment = FHE.sub(FHE.add(b.totalCapacityPaymentUSD, perfBonus), penalty);
        sId = settlementCount++;
        settlements[sId] = CapacityPeriodSettlement({
            bidId: bidId, settledCapacityMWh: settledCap, performanceBonusUSD: perfBonus,
            penaltyDeductionUSD: penalty, netPaymentUSD: netPayment,
            periodStart: periodStart, periodEnd: periodEnd
        });
        FHE.allowThis(settlements[sId].settledCapacityMWh); FHE.allow(settlements[sId].settledCapacityMWh, b.storageOperator);
        FHE.allowThis(settlements[sId].performanceBonusUSD); FHE.allow(settlements[sId].performanceBonusUSD, b.storageOperator);
        FHE.allowThis(settlements[sId].penaltyDeductionUSD); FHE.allow(settlements[sId].penaltyDeductionUSD, b.storageOperator);
        FHE.allowThis(settlements[sId].netPaymentUSD); FHE.allow(settlements[sId].netPaymentUSD, b.storageOperator);
        emit PeriodSettled(sId, bidId);
    }

    function allowGridStats(address viewer) external onlyOwner {
        FHE.allow(_totalCapacityCommittedMWh, viewer);
        FHE.allow(_totalCapacityPaymentsUSD, viewer);
    }
}
