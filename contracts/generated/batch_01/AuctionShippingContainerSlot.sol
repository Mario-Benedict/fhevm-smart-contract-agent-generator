// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionShippingContainerSlot
/// @notice Shipping container slot auction on ocean freight routes. Forwarders bid
///         encrypted freight rates per TEU. Carrier enforces encrypted volume commitments.
contract AuctionShippingContainerSlot is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct ShippingRoute {
        string origin;
        string destination;
        uint256 departureDate;
        euint32 availableTEUs;
        euint64 reserveRatePerTEU;
        uint256 auctionEnd;
        bool finalized;
        euint32 allocatedTEUs;
    }

    struct ForwarderBid {
        euint32 requestedTEUs;
        euint64 offeredRatePerTEU;
        euint8 creditScore;
        bool placed;
        bool allocated;
    }

    mapping(uint256 => ShippingRoute) private routes;
    uint256 public routeCount;
    mapping(uint256 => mapping(address => ForwarderBid)) private bids;
    mapping(uint256 => address[]) private forwarders;
    mapping(address => bool) public isRegisteredForwarder;
    euint8 private _minCreditScore;

    event RouteListed(uint256 indexed id, string origin, string dest);
    event BidSubmitted(uint256 indexed id, address forwarder);
    event SlotsAllocated(uint256 indexed id);

    constructor(externalEuint8 encMinCredit, bytes memory proof) Ownable(msg.sender) {
        _minCreditScore = FHE.fromExternal(encMinCredit, proof);
        FHE.allowThis(_minCreditScore);
    }

    function registerForwarder(address f) external onlyOwner { isRegisteredForwarder[f] = true; }

    function listRoute(
        string calldata origin, string calldata dest, uint256 departure,
        externalEuint32 encTEUs, bytes calldata tProof,
        externalEuint64 encReserve, bytes calldata rProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = routeCount++;
        routes[id].origin = origin;
        routes[id].destination = dest;
        routes[id].departureDate = departure;
        routes[id].availableTEUs = FHE.fromExternal(encTEUs, tProof);
        routes[id].reserveRatePerTEU = FHE.fromExternal(encReserve, rProof);
        routes[id].auctionEnd = block.timestamp + auctionDays * 1 days;
        routes[id].allocatedTEUs = FHE.asEuint32(0);
        FHE.allowThis(routes[id].availableTEUs);
        FHE.allowThis(routes[id].reserveRatePerTEU);
        FHE.allowThis(routes[id].allocatedTEUs);
        emit RouteListed(id, origin, dest);
    }

    function submitBid(
        uint256 routeId,
        externalEuint32 encTEUs, bytes calldata tProof,
        externalEuint64 encRate, bytes calldata rProof,
        externalEuint8 encCredit, bytes calldata cProof
    ) external nonReentrant {
        require(isRegisteredForwarder[msg.sender], "Not registered");
        ShippingRoute storage r = routes[routeId];
        require(block.timestamp < r.auctionEnd, "Closed");
        require(!bids[routeId][msg.sender].placed, "Already bid");
        bids[routeId][msg.sender] = ForwarderBid({
            requestedTEUs: FHE.fromExternal(encTEUs, tProof),
            offeredRatePerTEU: FHE.fromExternal(encRate, rProof),
            creditScore: FHE.fromExternal(encCredit, cProof),
            placed: true, allocated: false
        });
        FHE.allowThis(bids[routeId][msg.sender].requestedTEUs);
        FHE.allowThis(bids[routeId][msg.sender].offeredRatePerTEU);
        FHE.allowThis(bids[routeId][msg.sender].creditScore);
        forwarders[routeId].push(msg.sender);
        emit BidSubmitted(routeId, msg.sender);
    }

    function allocateSlots(uint256 routeId) external onlyOwner nonReentrant {
        ShippingRoute storage r = routes[routeId];
        require(block.timestamp >= r.auctionEnd && !r.finalized, "Cannot allocate");
        r.finalized = true;
        euint32 remaining = r.availableTEUs;
        address[] storage fs = forwarders[routeId];
        for (uint256 i = 0; i < fs.length; i++) {
            ForwarderBid storage b = bids[routeId][fs[i]];
            ebool creditOk = FHE.ge(b.creditScore, _minCreditScore);
            ebool rateOk = FHE.ge(b.offeredRatePerTEU, r.reserveRatePerTEU);
            ebool valid = FHE.and(creditOk, rateOk);
            ebool hasCapacity = FHE.ge(remaining, b.requestedTEUs);
            ebool accept = FHE.and(valid, hasCapacity);
            euint32 granted = FHE.select(accept, b.requestedTEUs, FHE.asEuint32(0));
            remaining = FHE.sub(remaining, granted);
            r.allocatedTEUs = FHE.add(r.allocatedTEUs, granted);
            b.allocated = FHE.isInitialized(accept);
            FHE.allowThis(remaining);
            FHE.allowThis(r.allocatedTEUs);
            FHE.allow(granted, fs[i]);
        }
        emit SlotsAllocated(routeId);
    }
}
