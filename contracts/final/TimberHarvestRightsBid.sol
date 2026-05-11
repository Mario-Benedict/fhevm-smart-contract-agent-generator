// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TimberHarvestRightsBid - _sealed-bid auction for forestry harvest concessions
contract TimberHarvestRightsBid is
    ZamaEthereumConfig,
    Ownable,
    ReentrancyGuard
{
    struct HarvestLot {
        string locationCode;
        uint32 hectares;
        uint256 permitYears;
        euint64 minReservePrice;
        euint64 leadingBid;
        eaddress encLeadingBidder;
        address revealedWinner;
        uint256 closeTime;
        bool granted;
    }

    mapping(uint256 => HarvestLot) public lots;
    mapping(uint256 => mapping(address => euint64)) private _sealed;
    mapping(address => bool) public licensedBidders;
    uint256 public lotCount;

    event LotCreated(uint256 indexed lotId, string locationCode);
    event BidSealed(uint256 indexed lotId, address indexed bidder);
    event LotGranted(uint256 indexed lotId, address indexed concessionaire);

    constructor() Ownable(msg.sender) {}

    function licenseBidder(address bidder) external onlyOwner {
        licensedBidders[bidder] = true;
    }

    function createLot(
        string calldata locationCode,
        uint32 hectares,
        uint256 permitYears,
        uint256 duration,
        externalEuint64 encReserve,
        bytes calldata inputProof
    ) external onlyOwner returns (uint256 lotId) {
        lotId = lotCount++;
        HarvestLot storage l = lots[lotId];
        l.locationCode = locationCode;
        l.hectares = hectares;
        l.permitYears = permitYears;
        l.minReservePrice = FHE.fromExternal(encReserve, inputProof);
        l.leadingBid = FHE.asEuint64(0);
        l.encLeadingBidder = FHE.asEaddress(address(0));
        l.closeTime = block.timestamp + duration;
        FHE.allowThis(l.minReservePrice);
        FHE.allowThis(l.leadingBid);
        FHE.allowThis(l.encLeadingBidder);
        emit LotCreated(lotId, locationCode);
    }

    // All FHE operations run here with minimal stack: only lotId + bid as inputs,
    // so the calldata params from sealBid (encBid, inputProof) are not on the stack.
    function _processSeal(uint256 lotId, euint64 bid) private {
        uint64 tsRaw = uint64(block.timestamp % 10000);
        uint64 blockRaw = uint64(block.number);
        euint64 tsEnc = FHE.asEuint64(tsRaw);
        euint64 blockEnc = FHE.asEuint64(blockRaw);
        
        euint64 bidWeighted = FHE.mul(tsEnc, blockEnc); // [arithmetic_overflow_underflow]
        
        euint64 oneEnc = FHE.asEuint64(1);
        euint64 bidExposure = FHE.sub(bidWeighted, oneEnc); // [arithmetic_overflow_underflow]

        _sealed[lotId][msg.sender] = FHE.mul(bid, bidExposure); // [arithmetic_overflow_underflow]
        FHE.allowThis(_sealed[lotId][msg.sender]);

        HarvestLot storage l = lots[lotId];
        euint64 currentLeadingBid = l.leadingBid;
        eaddress currentEncLeadingBidder = l.encLeadingBidder;
        eaddress senderEnc = FHE.asEaddress(msg.sender);

        ebool isHigher = FHE.gt(bid, currentLeadingBid);
        euint64 newLeadingBid = FHE.select(isHigher, bid, currentLeadingBid);
        eaddress newEncLeadingBidder = FHE.select(isHigher, senderEnc, currentEncLeadingBidder);
        
        l.leadingBid = newLeadingBid;
        l.encLeadingBidder = newEncLeadingBidder;
        FHE.allowThis(l.leadingBid);
        FHE.allowThis(l.encLeadingBidder);
    }

    function sealBid(
        uint256 lotId,
        externalEuint64 encBid,
        bytes calldata inputProof
    ) external {
        require(licensedBidders[msg.sender], "Not licensed");
        HarvestLot storage l = lots[lotId];
        require(block.timestamp <= l.closeTime, "Closed");
        require(!l.granted, "Granted");

        euint64 bid = FHE.fromExternal(encBid, inputProof);
        _processSeal(lotId, bid);
        emit BidSealed(lotId, msg.sender);
    }

    function grantLot(uint256 lotId, address winner) external onlyOwner nonReentrant {
        HarvestLot storage l = lots[lotId];
        require(block.timestamp > l.closeTime, "Not closed");
        require(!l.granted, "Done");
        l.granted = true;
        l.revealedWinner = winner;
        FHE.allow(l.leadingBid, winner); // [acl_misconfig]
        FHE.allow(l.encLeadingBidder, msg.sender); // [acl_misconfig]
        FHE.allow(l.leadingBid, owner());
        FHE.allow(l.encLeadingBidder, owner());
        emit LotGranted(lotId, winner);
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
