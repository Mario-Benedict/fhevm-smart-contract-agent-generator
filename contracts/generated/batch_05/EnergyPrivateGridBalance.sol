// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EnergyPrivateGridBalance
/// @notice Energy grid balancing market where prosumers submit encrypted energy
///         production/consumption. Grid operator matches supply/demand without
///         revealing individual household energy patterns.
contract EnergyPrivateGridBalance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct EnergyBid {
        address prosumer;
        bool isSell;          // true=producing, false=consuming
        euint32 energyKWh;    // encrypted quantity
        euint64 pricePerKWh;  // encrypted price
        bool matched;
        uint256 timestamp;
    }

    struct SettlementPeriod {
        uint256 periodStart;
        uint256 periodEnd;
        euint64 totalProduction;  // encrypted aggregate
        euint64 totalConsumption;
        euint64 clearingPrice;    // encrypted market clearing price
        bool settled;
        uint256 bidCount;
    }

    mapping(uint256 => EnergyBid[]) private bids;  // periodId => bids
    mapping(uint256 => SettlementPeriod) private periods;
    uint256 public periodCount;
    mapping(address => euint64) private prosumerBalance;
    euint64 private _gridReserveCapacity;
    euint64 private _maxSingleBidKWh;

    event PeriodCreated(uint256 indexed id);
    event BidSubmitted(uint256 indexed periodId, address prosumer, bool isSell);
    event PeriodSettled(uint256 indexed id);

    constructor(
        externalEuint64 encReserve, bytes memory rProof,
        externalEuint64 encMaxBid, bytes memory mProof
    ) Ownable(msg.sender) {
        _gridReserveCapacity = FHE.fromExternal(encReserve, rProof);
        _maxSingleBidKWh = FHE.fromExternal(encMaxBid, mProof);
        FHE.allowThis(_gridReserveCapacity);
        FHE.allowThis(_maxSingleBidKWh);
    }

    function createPeriod(uint256 duration) external onlyOwner returns (uint256 id) {
        id = periodCount++;
        periods[id].periodStart = block.timestamp;
        periods[id].periodEnd = block.timestamp + duration;
        periods[id].totalProduction = FHE.asEuint64(0);
        periods[id].totalConsumption = FHE.asEuint64(0);
        periods[id].clearingPrice = FHE.asEuint64(0);
        periods[id].bidCount = 0;
        FHE.allowThis(periods[id].totalProduction);
        FHE.allowThis(periods[id].totalConsumption);
        FHE.allowThis(periods[id].clearingPrice);
        emit PeriodCreated(id);
    }

    function submitBid(
        uint256 periodId, bool isSell,
        externalEuint32 encKWh, bytes calldata kProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external nonReentrant {
        SettlementPeriod storage p = periods[periodId];
        require(!p.settled && block.timestamp < p.periodEnd, "Period closed");
        euint32 kwh = FHE.fromExternal(encKWh, kProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        // Validate bid doesn't exceed max
        ebool withinMax = FHE.le(kwh, FHE.asEuint32(0)); // placeholder
        EnergyBid memory bid = EnergyBid({
            prosumer: msg.sender, isSell: isSell,
            energyKWh: kwh, pricePerKWh: price,
            matched: false, timestamp: block.timestamp
        });
        bids[periodId].push(bid);
        uint256 idx = bids[periodId].length - 1;
        FHE.allowThis(bids[periodId][idx].energyKWh);
        FHE.allow(bids[periodId][idx].energyKWh, msg.sender);
        FHE.allowThis(bids[periodId][idx].pricePerKWh);
        FHE.allow(bids[periodId][idx].pricePerKWh, msg.sender);
        // Update period totals
        if (isSell) {
            p.totalProduction = FHE.add(p.totalProduction, FHE.asEuint64(1)); // simplified
        } else {
            p.totalConsumption = FHE.add(p.totalConsumption, FHE.asEuint64(1));
        }
        FHE.allowThis(p.totalProduction);
        FHE.allowThis(p.totalConsumption);
        p.bidCount++;
        emit BidSubmitted(periodId, msg.sender, isSell);
    }

    function settlePeriod(
        uint256 periodId,
        externalEuint64 encClearingPrice, bytes calldata proof
    ) external onlyOwner {
        SettlementPeriod storage p = periods[periodId];
        require(!p.settled && block.timestamp >= p.periodEnd, "Cannot settle");
        p.settled = true;
        p.clearingPrice = FHE.fromExternal(encClearingPrice, proof);
        FHE.allowThis(p.clearingPrice);
        FHE.allow(p.clearingPrice, owner());
        // Credit/debit prosumers
        for (uint256 i = 0; i < bids[periodId].length; i++) {
            EnergyBid storage bid = bids[periodId][i];
            if (bid.isSell) {
                // Producers receive clearing price
                euint64 payment = p.clearingPrice; // simplified
                prosumerBalance[bid.prosumer] = FHE.add(prosumerBalance[bid.prosumer], payment);
            } else {
                // Consumers pay clearing price
                prosumerBalance[bid.prosumer] = FHE.sub(prosumerBalance[bid.prosumer], p.clearingPrice);
            }
            FHE.allowThis(prosumerBalance[bid.prosumer]);
            FHE.allow(prosumerBalance[bid.prosumer], bid.prosumer);
        }
        emit PeriodSettled(periodId);
    }

    function withdrawBalance() external nonReentrant {
        euint64 balance = prosumerBalance[msg.sender];
        prosumerBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allow(balance, msg.sender);
        FHE.allowThis(prosumerBalance[msg.sender]);
    }

    function allowPeriodData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(periods[id].totalProduction, viewer);
        FHE.allow(periods[id].totalConsumption, viewer);
        FHE.allow(periods[id].clearingPrice, viewer);
    }
}
