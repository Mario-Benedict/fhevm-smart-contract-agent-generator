// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TimberHarvestRightsBid - Sealed-bid auction for forestry harvest concessions
contract TimberHarvestRightsBid is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct HarvestLot {
        string locationCode;
        uint32 hectares;
        uint256 permitYears;
        euint64 minReservePrice;
        euint64 leadingBid;
        address leadingBidder;
        uint256 closeTime;
        bool granted;
    }

    mapping(uint256 => HarvestLot) public lots;
    mapping(uint256 => mapping(address => euint64)) private sealed;
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
        externalEuint64 calldata encReserve,
        bytes calldata inputProof
    ) external onlyOwner returns (uint256 lotId) {
        lotId = lotCount++;
        HarvestLot storage l = lots[lotId];
        l.locationCode = locationCode;
        l.hectares = hectares;
        l.permitYears = permitYears;
        l.minReservePrice = FHE.fromExternal(encReserve, inputProof);
        l.leadingBid = FHE.asEuint64(0);
        l.closeTime = block.timestamp + duration;
        FHE.allowThis(l.minReservePrice);
        FHE.allowThis(l.leadingBid);
        emit LotCreated(lotId, locationCode);
    }

    function sealBid(uint256 lotId, externalEuint64 calldata encBid, bytes calldata inputProof) external {
        require(licensedBidders[msg.sender], "Not licensed");
        HarvestLot storage l = lots[lotId];
        require(block.timestamp <= l.closeTime, "Closed");
        require(!l.granted, "Granted");

        euint64 bid = FHE.fromExternal(encBid, inputProof);
        sealed[lotId][msg.sender] = bid;
        FHE.allowThis(sealed[lotId][msg.sender]);

        ebool isHigher = FHE.gt(bid, l.leadingBid);
        l.leadingBid = FHE.select(isHigher, bid, l.leadingBid);
        FHE.allowThis(l.leadingBid);
        if (isHigher.unwrap() != 0) l.leadingBidder = msg.sender;
        emit BidSealed(lotId, msg.sender);
    }

    function grantLot(uint256 lotId) external onlyOwner nonReentrant {
        HarvestLot storage l = lots[lotId];
        require(block.timestamp > l.closeTime, "Not closed");
        require(!l.granted, "Done");
        l.granted = true;
        FHE.allow(l.leadingBid, l.leadingBidder);
        FHE.allow(l.leadingBid, owner());
        emit LotGranted(lotId, l.leadingBidder);
    }
}
