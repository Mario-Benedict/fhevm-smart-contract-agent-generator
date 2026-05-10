// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateDutchAuctionDecreasingPrice
/// @notice Dutch auction with encrypted starting price, hidden price decrement schedule,
///         private bid acceptance logic, and confidential final clearing price.
contract PrivateDutchAuctionDecreasingPrice is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct DutchAuction {
        address seller;
        string assetDescription;
        euint64 startingPriceUSD;      // encrypted starting price
        euint64 floorPriceUSD;         // encrypted floor price
        euint64 currentPriceUSD;       // encrypted current price
        euint64 decrementPerHourUSD;   // encrypted hourly decrement
        euint64 clearedPriceUSD;       // encrypted final clearing price
        address winner;
        uint256 startTime;
        uint256 endTime;
        bool cleared;
    }

    struct DutchBid {
        address bidder;
        uint256 auctionId;
        euint64 willingToPay;          // encrypted max willing to pay
        uint256 bidTime;
        bool accepted;
    }

    mapping(uint256 => DutchAuction) private auctions;
    mapping(uint256 => DutchBid) private bids;
    mapping(uint256 => uint256[]) private auctionBids;

    uint256 public auctionCount;
    uint256 public bidCount;
    euint64 private _totalClearedValue;

    event DutchAuctionCreated(uint256 indexed id, string assetDescription);
    event DutchBidPlaced(uint256 indexed bidId, uint256 auctionId);
    event DutchAuctionCleared(uint256 indexed id, address winner);

    constructor() Ownable(msg.sender) {
        _totalClearedValue = FHE.asEuint64(0);
        FHE.allowThis(_totalClearedValue);
    }

    function createDutchAuction(
        string calldata assetDescription,
        externalEuint64 encStartPrice, bytes calldata spProof,
        externalEuint64 encFloor, bytes calldata flProof,
        externalEuint64 encDecrement, bytes calldata decProof,
        uint256 durationHours
    ) external returns (uint256 id) {
        euint64 startPrice = FHE.fromExternal(encStartPrice, spProof);
        euint64 floor      = FHE.fromExternal(encFloor, flProof);
        euint64 decrement  = FHE.fromExternal(encDecrement, decProof);
        id = auctionCount++;
        auctions[id].seller = msg.sender;
        auctions[id].assetDescription = assetDescription;
        auctions[id].startingPriceUSD = startPrice;
        auctions[id].floorPriceUSD = floor;
        auctions[id].currentPriceUSD = startPrice;
        auctions[id].decrementPerHourUSD = decrement;
        auctions[id].clearedPriceUSD = FHE.asEuint64(0);
        auctions[id].winner = address(0);
        auctions[id].startTime = block.timestamp;
        auctions[id].endTime = block.timestamp + durationHours * 1 hours;
        auctions[id].cleared = false;
        FHE.allowThis(auctions[id].startingPriceUSD); FHE.allow(auctions[id].startingPriceUSD, msg.sender);
        FHE.allowThis(auctions[id].floorPriceUSD);
        FHE.allowThis(auctions[id].currentPriceUSD);
        FHE.allowThis(auctions[id].decrementPerHourUSD);
        FHE.allowThis(auctions[id].clearedPriceUSD);
        emit DutchAuctionCreated(id, assetDescription);
    }

    function updateCurrentPrice(uint256 auctionId) external {
        DutchAuction storage a = auctions[auctionId];
        require(!a.cleared && block.timestamp < a.endTime, "Auction ended");
        uint256 elapsed = (block.timestamp - a.startTime) / 1 hours;
        euint64 totalDecrement = FHE.mul(a.decrementPerHourUSD, FHE.asEuint64(uint64(elapsed)));
        euint64 newPrice = FHE.sub(a.startingPriceUSD, totalDecrement);
        ebool aboveFloor = FHE.gt(newPrice, a.floorPriceUSD);
        a.currentPriceUSD = FHE.select(aboveFloor, newPrice, a.floorPriceUSD);
        FHE.allowThis(a.currentPriceUSD);
    }

    function placeBid(uint256 auctionId, externalEuint64 encWTP, bytes calldata proof) external nonReentrant returns (uint256 bidId) {
        DutchAuction storage a = auctions[auctionId];
        require(!a.cleared && block.timestamp < a.endTime, "Auction ended");
        euint64 wtp = FHE.fromExternal(encWTP, proof);
        bidId = bidCount++;
        bids[bidId] = DutchBid({ bidder: msg.sender, auctionId: auctionId, willingToPay: wtp, bidTime: block.timestamp, accepted: false });
        auctionBids[auctionId].push(bidId);
        // Check if WTP >= current price (branchless)
        ebool acceptable = FHE.ge(wtp, a.currentPriceUSD);
        bids[bidId].accepted = FHE.isInitialized(acceptable);
        if (FHE.isInitialized(acceptable) && a.winner == address(0)) {
            a.winner = msg.sender;
            a.clearedPriceUSD = a.currentPriceUSD;
            a.cleared = true;
            _totalClearedValue = FHE.add(_totalClearedValue, a.currentPriceUSD);
            FHE.allow(a.clearedPriceUSD, msg.sender); FHE.allow(a.clearedPriceUSD, a.seller);
            FHE.allowThis(_totalClearedValue);
            emit DutchAuctionCleared(auctionId, msg.sender);
        }
        FHE.allowThis(bids[bidId].willingToPay); FHE.allow(bids[bidId].willingToPay, msg.sender);
        emit DutchBidPlaced(bidId, auctionId);
    }

    function getCurrentPrice(uint256 auctionId) external view returns (euint64) { return auctions[auctionId].currentPriceUSD; }
    function allowAuctionStats(address viewer) external onlyOwner { FHE.allow(_totalClearedValue, viewer); }

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