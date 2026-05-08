// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateEventTicketAuction
/// @notice Encrypted ticket auction for exclusive events: sealed bids,
///         encrypted seat categories, and private waitlist with encrypted priority scores.
contract PrivateEventTicketAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SeatCategory { General, Premium, VIP, Platinum }

    struct Event {
        string eventName;
        string venue;
        uint256 eventDate;
        mapping(SeatCategory => euint32) ticketsAvailable; // encrypted per category
        mapping(SeatCategory => euint64) floorPrice;       // encrypted floor price
        bool saleOpen;
    }

    struct TicketBid {
        SeatCategory category;
        euint64 bidAmount;         // encrypted bid
        euint8 priorityScore;     // encrypted waitlist priority
        bool won;
        bool claimed;
    }

    mapping(uint256 => Event) private events;
    mapping(uint256 => mapping(address => TicketBid)) private bids;
    mapping(address => euint64) private _refundBalance;
    uint256 public eventCount;
    euint64 private _totalRevenue;

    event EventCreated(uint256 indexed id, string name);
    event BidSubmitted(uint256 indexed eventId, address bidder, SeatCategory cat);
    event TicketAwarded(uint256 indexed eventId, address winner, SeatCategory cat);
    event RefundIssued(address indexed bidder);

    constructor() Ownable(msg.sender) {
        _totalRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalRevenue);
    }

    function createEvent(string calldata name, string calldata venue, uint256 eventDate) external onlyOwner returns (uint256 id) {
        id = eventCount++;
        events[id].eventName = name;
        events[id].venue = venue;
        events[id].eventDate = eventDate;
        events[id].saleOpen = false;
        emit EventCreated(id, name);
    }

    function setTicketSupply(
        uint256 eventId, SeatCategory cat,
        externalEuint32 encQty, bytes calldata qProof,
        externalEuint64 encFloor, bytes calldata fProof
    ) external onlyOwner {
        euint32 qty = FHE.fromExternal(encQty, qProof);
        euint64 floor = FHE.fromExternal(encFloor, fProof);
        events[eventId].ticketsAvailable[cat] = qty;
        events[eventId].floorPrice[cat] = floor;
        FHE.allowThis(events[eventId].ticketsAvailable[cat]);
        FHE.allowThis(events[eventId].floorPrice[cat]);
    }

    function openSale(uint256 eventId) external onlyOwner { events[eventId].saleOpen = true; }
    function closeSale(uint256 eventId) external onlyOwner { events[eventId].saleOpen = false; }

    function submitBid(
        uint256 eventId, SeatCategory cat,
        externalEuint64 encBid, bytes calldata bProof,
        externalEuint8 encPriority, bytes calldata pProof
    ) external nonReentrant {
        require(events[eventId].saleOpen, "Sale closed");
        euint64 bid = FHE.fromExternal(encBid, bProof);
        euint8 priority = FHE.fromExternal(encPriority, pProof);
        // Ensure bid >= floor price
        ebool meetsFloor = FHE.ge(bid, events[eventId].floorPrice[cat]);
        euint64 acceptedBid = FHE.select(meetsFloor, bid, FHE.asEuint64(0));
        bids[eventId][msg.sender] = TicketBid({
            category: cat, bidAmount: acceptedBid, priorityScore: priority, won: false, claimed: false
        });
        FHE.allowThis(bids[eventId][msg.sender].bidAmount);
        FHE.allow(bids[eventId][msg.sender].bidAmount, msg.sender);
        FHE.allowThis(bids[eventId][msg.sender].priorityScore);
        if (!FHE.isInitialized(_refundBalance[msg.sender])) {
            _refundBalance[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_refundBalance[msg.sender]);
        }
        emit BidSubmitted(eventId, msg.sender, cat);
    }

    function awardTicket(uint256 eventId, address bidder) external onlyOwner {
        TicketBid storage b = bids[eventId][bidder];
        require(!b.won, "Already won");
        Event storage ev = events[eventId];
        // Check if tickets available
        ebool hasTickets = FHE.gt(ev.ticketsAvailable[b.category], FHE.asEuint32(0));
        euint32 newQty = FHE.select(hasTickets,
            FHE.sub(ev.ticketsAvailable[b.category], FHE.asEuint32(1)),
            ev.ticketsAvailable[b.category]);
        ev.ticketsAvailable[b.category] = newQty;
        FHE.allowThis(ev.ticketsAvailable[b.category]);
        b.won = true;
        _totalRevenue = FHE.add(_totalRevenue, b.bidAmount);
        FHE.allowThis(_totalRevenue);
        FHE.allow(b.bidAmount, bidder);
        emit TicketAwarded(eventId, bidder, b.category);
    }

    function issueRefund(uint256 eventId, address bidder) external onlyOwner {
        TicketBid storage b = bids[eventId][bidder];
        require(!b.won && !b.claimed, "Invalid");
        b.claimed = true;
        _refundBalance[bidder] = FHE.add(_refundBalance[bidder], b.bidAmount);
        FHE.allowThis(_refundBalance[bidder]);
        FHE.allow(_refundBalance[bidder], bidder);
        emit RefundIssued(bidder);
    }

    function withdrawRefund() external nonReentrant {
        euint64 refund = _refundBalance[msg.sender];
        _refundBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_refundBalance[msg.sender]);
        FHE.allow(refund, msg.sender);
    }

    function allowEventStats(uint256 eventId, SeatCategory cat, address viewer) external onlyOwner {
        FHE.allow(events[eventId].ticketsAvailable[cat], viewer);
        FHE.allow(events[eventId].floorPrice[cat], viewer);
    }
}
