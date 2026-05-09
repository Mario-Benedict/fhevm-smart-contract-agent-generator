// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateTicketingPlatform - Encrypted ticket sales with private pricing tiers and anti-scalping controls
contract PrivateTicketingPlatform is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Event {
        string  eventName;
        uint256 eventDate;
        euint32 totalCapacity;
        euint32 ticketsSold;
        euint64 basePrice;
        euint64 maxResaleMarkupBps; // max resale markup above face value
        bool    saleOpen;
        bool    finalized;
    }

    struct Ticket {
        uint256 eventId;
        address owner;
        euint64 pricePaid;
        euint64 faceValue;
        bool    used;
        bool    forSale;
        euint64 resaleAskPrice;
    }

    mapping(uint256 => Event)   public events;
    mapping(uint256 => Ticket)  public tickets;
    mapping(address => uint256[]) public holderTickets;
    mapping(uint256 => uint256[]) public eventTickets;
    uint256 public eventCount;
    uint256 public ticketCount;

    event EventCreated(uint256 indexed eventId, string name);
    event TicketPurchased(uint256 indexed ticketId, address indexed buyer);
    event TicketListedForResale(uint256 indexed ticketId, address indexed seller);
    event TicketResold(uint256 indexed ticketId, address indexed newOwner);
    event TicketUsed(uint256 indexed ticketId);

    constructor() Ownable(msg.sender) {}

    function createEvent(
        string calldata eventName,
        uint256 eventDate,
        externalEuint32 calldata encCapacity,   bytes calldata capProof,
        externalEuint64 calldata encBasePrice,  bytes calldata priceProof,
        externalEuint64 calldata encMarkupCap,  bytes calldata markupProof
    ) external onlyOwner returns (uint256 eventId) {
        eventId = eventCount++;
        Event storage e = events[eventId];
        e.eventName          = eventName;
        e.eventDate          = eventDate;
        e.totalCapacity      = FHE.fromExternal(encCapacity, capProof);
        e.ticketsSold        = FHE.asEuint32(0);
        e.basePrice          = FHE.fromExternal(encBasePrice, priceProof);
        e.maxResaleMarkupBps = FHE.fromExternal(encMarkupCap, markupProof);
        e.saleOpen           = true;
        FHE.allowThis(e.totalCapacity); FHE.allowThis(e.ticketsSold);
        FHE.allowThis(e.basePrice); FHE.allowThis(e.maxResaleMarkupBps);
        FHE.allow(e.basePrice, owner());
        emit EventCreated(eventId, eventName);
    }

    function purchaseTicket(uint256 eventId) external nonReentrant returns (uint256 ticketId) {
        Event storage e = events[eventId];
        require(e.saleOpen && !e.finalized, "Sale closed");
        ebool hasCapacity = FHE.lt(e.ticketsSold, e.totalCapacity);
        require(hasCapacity.unwrap() != 0, "Sold out");
        ticketId = ticketCount++;
        Ticket storage t = tickets[ticketId];
        t.eventId    = eventId;
        t.owner      = msg.sender;
        t.pricePaid  = e.basePrice;
        t.faceValue  = e.basePrice;
        FHE.allowThis(t.pricePaid); FHE.allowThis(t.faceValue);
        FHE.allow(t.pricePaid, msg.sender);
        e.ticketsSold = FHE.add(e.ticketsSold, FHE.asEuint32(1));
        FHE.allowThis(e.ticketsSold);
        holderTickets[msg.sender].push(ticketId);
        eventTickets[eventId].push(ticketId);
        emit TicketPurchased(ticketId, msg.sender);
    }

    function listForResale(uint256 ticketId, externalEuint64 calldata encAsk, bytes calldata inputProof) external {
        Ticket storage t = tickets[ticketId];
        require(t.owner == msg.sender && !t.used, "Not owner or used");
        euint64 ask = FHE.fromExternal(encAsk, inputProof);
        Event storage e = events[t.eventId];
        // enforce markup cap
        euint64 maxAllowed = FHE.add(t.faceValue,
            FHE.div(FHE.mul(t.faceValue, FHE.asEuint64(e.maxResaleMarkupBps.unwrap())), FHE.asEuint64(10000))
        );
        ebool withinCap = FHE.le(ask, maxAllowed);
        t.resaleAskPrice = FHE.select(withinCap, ask, maxAllowed);
        t.forSale        = true;
        FHE.allowThis(t.resaleAskPrice);
        FHE.allow(t.resaleAskPrice, msg.sender);
        emit TicketListedForResale(ticketId, msg.sender);
    }

    function buyResaleTicket(uint256 ticketId) external nonReentrant {
        Ticket storage t = tickets[ticketId];
        require(t.forSale && !t.used, "Not for sale");
        address seller = t.owner;
        t.owner   = msg.sender;
        t.forSale = false;
        t.pricePaid = t.resaleAskPrice;
        FHE.allowThis(t.pricePaid);
        FHE.allow(t.pricePaid, msg.sender);
        FHE.allowTransient(t.resaleAskPrice, seller);
        holderTickets[msg.sender].push(ticketId);
        emit TicketResold(ticketId, msg.sender);
    }

    function scanTicket(uint256 ticketId) external onlyOwner {
        require(!tickets[ticketId].used, "Already scanned");
        tickets[ticketId].used = true;
        emit TicketUsed(ticketId);
    }
}
