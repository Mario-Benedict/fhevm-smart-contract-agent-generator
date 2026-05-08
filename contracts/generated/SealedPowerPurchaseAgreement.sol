// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SealedPowerPurchaseAgreement - Encrypted PPA between renewable energy producers and buyers
contract SealedPowerPurchaseAgreement is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct PPA {
        address producer;
        address buyer;
        euint64 strikePrice;        // encrypted price per MWh
        euint64 contractedCapacity; // encrypted MWh/year
        euint64 totalDelivered;
        euint64 totalSettled;
        uint256 startDate;
        uint256 endDate;
        bool    active;
    }

    struct DeliveryRecord {
        uint256 period;
        euint64 mwhDelivered;
        euint64 marketPrice;     // reference market price
        euint64 settlementAmount;
        bool    settled;
    }

    mapping(uint256 => PPA) public agreements;
    mapping(uint256 => DeliveryRecord[]) private deliveries;
    mapping(address => bool) public certifiedProducers;
    mapping(address => bool) public qualifiedBuyers;
    uint256 public agreementCount;

    event PPAExecuted(uint256 indexed ppaId, address producer, address buyer);
    event DeliveryRecorded(uint256 indexed ppaId, uint256 deliveryIdx);
    event SettlementProcessed(uint256 indexed ppaId, uint256 deliveryIdx);

    constructor() Ownable(msg.sender) {}

    function certifyProducer(address producer) external onlyOwner { certifiedProducers[producer] = true; }
    function qualifyBuyer(address buyer) external onlyOwner { qualifiedBuyers[buyer] = true; }

    function executePPA(
        address buyer,
        externalEuint64 calldata encStrike,   bytes calldata strikeProof,
        externalEuint64 calldata encCapacity, bytes calldata capProof,
        uint256 startDays, uint256 durationDays
    ) external returns (uint256 ppaId) {
        require(certifiedProducers[msg.sender], "Not certified producer");
        require(qualifiedBuyers[buyer], "Not qualified buyer");
        ppaId = agreementCount++;
        PPA storage p = agreements[ppaId];
        p.producer           = msg.sender;
        p.buyer              = buyer;
        p.strikePrice        = FHE.fromExternal(encStrike,   strikeProof);
        p.contractedCapacity = FHE.fromExternal(encCapacity, capProof);
        p.totalDelivered     = FHE.asEuint64(0);
        p.totalSettled       = FHE.asEuint64(0);
        p.startDate          = block.timestamp + startDays * 1 days;
        p.endDate            = p.startDate + durationDays * 1 days;
        p.active             = true;
        FHE.allowThis(p.strikePrice); FHE.allowThis(p.contractedCapacity);
        FHE.allowThis(p.totalDelivered); FHE.allowThis(p.totalSettled);
        FHE.allow(p.strikePrice, msg.sender); FHE.allow(p.strikePrice, buyer);
        FHE.allow(p.contractedCapacity, msg.sender);
        emit PPAExecuted(ppaId, msg.sender, buyer);
    }

    function recordDelivery(
        uint256 ppaId,
        uint256 period,
        externalEuint64 calldata encMWh,    bytes calldata mwhProof,
        externalEuint64 calldata encMarket, bytes calldata marketProof
    ) external {
        PPA storage p = agreements[ppaId];
        require(p.producer == msg.sender, "Not producer");
        require(p.active, "Inactive");
        euint64 mwh    = FHE.fromExternal(encMWh,    mwhProof);
        euint64 market = FHE.fromExternal(encMarket, marketProof);
        // settlement = (market - strike) * mwh  (CfD settlement)
        ebool marketAbove = FHE.gt(market, p.strikePrice);
        euint64 spread = FHE.select(marketAbove, FHE.sub(market, p.strikePrice), FHE.sub(p.strikePrice, market));
        euint64 settlement = FHE.mul(mwh, spread);

        deliveries[ppaId].push(DeliveryRecord({
            period: period, mwhDelivered: mwh, marketPrice: market,
            settlementAmount: settlement, settled: false
        }));
        uint256 idx = deliveries[ppaId].length - 1;
        p.totalDelivered = FHE.add(p.totalDelivered, mwh);
        FHE.allowThis(deliveries[ppaId][idx].mwhDelivered); FHE.allowThis(deliveries[ppaId][idx].settlementAmount);
        FHE.allowThis(p.totalDelivered);
        FHE.allow(deliveries[ppaId][idx].settlementAmount, p.buyer);
        FHE.allow(deliveries[ppaId][idx].settlementAmount, p.producer);
        emit DeliveryRecorded(ppaId, idx);
    }

    function processSettlement(uint256 ppaId, uint256 deliveryIdx) external onlyOwner nonReentrant {
        PPA storage p = agreements[ppaId];
        DeliveryRecord storage d = deliveries[ppaId][deliveryIdx];
        require(!d.settled, "Settled");
        d.settled = true;
        p.totalSettled = FHE.add(p.totalSettled, d.settlementAmount);
        FHE.allowThis(p.totalSettled);
        FHE.allowTransient(d.settlementAmount, p.buyer);
        emit SettlementProcessed(ppaId, deliveryIdx);
    }
}
