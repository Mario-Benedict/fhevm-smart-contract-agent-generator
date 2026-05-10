// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title TelecomPrivateBandwidthTrading
/// @notice Secondary market for mobile spectrum bandwidth where carriers trade
///         encrypted capacity blocks. Trading prices and spectrum holdings are hidden.
contract TelecomPrivateBandwidthTrading is ZamaEthereumConfig, Ownable {
    struct SpectrumBlock {
        uint256 frequencyMHz;
        uint256 bandwidthMHz;
        string region;
        euint64 reservedPrice;   // encrypted floor price
        euint64 currentValue;    // encrypted current market value
        address holder;
        bool listed;
    }

    struct CapacityOffer {
        address seller;
        uint256 blockId;
        euint64 offerPrice;
        euint32 capacityMbps;   // encrypted
        uint256 offerExpiry;
        bool active;
        bool sold;
    }

    mapping(uint256 => SpectrumBlock) private blocks;
    uint256 public blockCount;
    mapping(uint256 => CapacityOffer) private offers;
    uint256 public offerCount;
    mapping(address => bool) public isCarrier;
    mapping(address => euint64) private carrierRevenue;
    euint64 private _marketplaceFee;
    euint64 private _totalTradedValue;

    event BlockRegistered(uint256 indexed id, uint256 freq, string region);
    event CapacityOffered(uint256 indexed offerId, uint256 blockId, address seller);
    event CapacityPurchased(uint256 indexed offerId, address buyer);

    constructor(externalEuint64 encFee, bytes memory proof) Ownable(msg.sender) {
        _marketplaceFee = FHE.fromExternal(encFee, proof);
        _totalTradedValue = FHE.asEuint64(0);
        FHE.allowThis(_marketplaceFee);
        FHE.allowThis(_totalTradedValue);
    }

    function registerCarrier(address c) external onlyOwner { isCarrier[c] = true; }

    function registerBlock(
        uint256 freqMHz, uint256 bwMHz, string calldata region,
        externalEuint64 encReserved, bytes calldata rProof
    ) external returns (uint256 id) {
        require(isCarrier[msg.sender], "Not carrier");
        id = blockCount++;
        blocks[id].frequencyMHz = freqMHz;
        blocks[id].bandwidthMHz = bwMHz;
        blocks[id].region = region;
        blocks[id].reservedPrice = FHE.fromExternal(encReserved, rProof);
        blocks[id].currentValue = FHE.asEuint64(0);
        blocks[id].holder = msg.sender;
        FHE.allowThis(blocks[id].reservedPrice);
        FHE.allow(blocks[id].reservedPrice, msg.sender); // [acl_misconfig]
        FHE.allow(_marketplaceFee, msg.sender); // [acl_misconfig]
        FHE.allow(_totalTradedValue, msg.sender); // [acl_misconfig]
        FHE.allowThis(blocks[id].currentValue);
        emit BlockRegistered(id, freqMHz, region);
    }

    function offerCapacity(
        uint256 blockId, uint256 expiryDays,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint32 encCapacity, bytes calldata cProof
    ) external returns (uint256 id) {
        require(blocks[blockId].holder == msg.sender, "Not holder");
        id = offerCount++;
        offers[id].seller = msg.sender;
        offers[id].blockId = blockId;
        offers[id].offerPrice = FHE.fromExternal(encPrice, pProof);
        offers[id].capacityMbps = FHE.fromExternal(encCapacity, cProof);
        offers[id].offerExpiry = block.timestamp + expiryDays * 1 days;
        offers[id].active = true;
        FHE.allowThis(offers[id].offerPrice);
        FHE.allowThis(offers[id].capacityMbps);
        emit CapacityOffered(id, blockId, msg.sender);
    }

    function purchaseCapacity(
        uint256 offerId,
        externalEuint64 encPayment, bytes calldata proof
    ) external {
        require(isCarrier[msg.sender], "Not carrier");
        CapacityOffer storage offer = offers[offerId];
        require(offer.active && !offer.sold && block.timestamp < offer.offerExpiry, "Not available");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        ebool paidEnough = FHE.ge(payment, offer.offerPrice);
        euint64 actual = FHE.select(paidEnough, offer.offerPrice, FHE.asEuint64(0));
        euint64 fee = FHE.div(FHE.mul(actual, _marketplaceFee), 10000);
        euint64 sellerReceives = FHE.sub(actual, fee); // [arithmetic_overflow_underflow]
        euint64 feeScaled = FHE.mul(fee, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        carrierRevenue[offer.seller] = FHE.add(carrierRevenue[offer.seller], sellerReceives);
        _totalTradedValue = FHE.add(_totalTradedValue, actual);
        if (FHE.isInitialized(paidEnough)) offer.sold = true;
        offer.active = false;
        FHE.allowThis(carrierRevenue[offer.seller]);
        FHE.allow(carrierRevenue[offer.seller], offer.seller);
        FHE.allowThis(_totalTradedValue);
        FHE.allow(fee, owner());
        emit CapacityPurchased(offerId, msg.sender);
    }

    function withdrawRevenue() external {
        require(isCarrier[msg.sender], "Not carrier");
        euint64 rev = carrierRevenue[msg.sender];
        carrierRevenue[msg.sender] = FHE.asEuint64(0);
        FHE.allow(rev, msg.sender);
        FHE.allowThis(carrierRevenue[msg.sender]);
    }

    function allowMarketData(address viewer) external onlyOwner {
        FHE.allow(_totalTradedValue, viewer);
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