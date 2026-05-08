// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CryptoLotteryDraw - Encrypted number lottery with verifiable random draws
contract CryptoLotteryDraw is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Ticket {
        address owner;
        euint8 pickedNumber; // 1-100
    }

    struct Draw {
        euint8 winningNumber;
        euint64 prizePool;
        uint256 closeTime;
        bool drawn;
        bool finalized;
        uint256 ticketCount;
    }

    mapping(uint256 => Draw) public draws;
    mapping(uint256 => mapping(uint256 => Ticket)) private tickets;
    mapping(uint256 => mapping(address => uint256[])) private playerTickets;
    uint256 public drawCount;
    uint64 public ticketPriceUSD;

    event DrawCreated(uint256 indexed drawId);
    event TicketPurchased(uint256 indexed drawId, address indexed buyer, uint256 ticketId);
    event NumberDrawn(uint256 indexed drawId);
    event WinnerPaid(uint256 indexed drawId, address indexed winner);

    constructor(uint64 _ticketPriceUSD) Ownable(msg.sender) {
        ticketPriceUSD = _ticketPriceUSD;
    }

    function createDraw(uint256 duration) external onlyOwner returns (uint256 drawId) {
        drawId = drawCount++;
        Draw storage d = draws[drawId];
        d.closeTime = block.timestamp + duration;
        d.prizePool = FHE.asEuint64(0);
        d.winningNumber = FHE.asEuint8(0);
        FHE.allowThis(d.prizePool);
        FHE.allowThis(d.winningNumber);
        emit DrawCreated(drawId);
    }

    function buyTicket(
        uint256 drawId,
        externalEuint8 calldata encNumber,
        bytes calldata inputProof
    ) external nonReentrant returns (uint256 ticketId) {
        Draw storage d = draws[drawId];
        require(block.timestamp <= d.closeTime, "Draw closed");
        require(!d.drawn, "Already drawn");

        euint8 picked = FHE.fromExternal(encNumber, inputProof);
        ticketId = d.ticketCount++;
        tickets[drawId][ticketId] = Ticket({ owner: msg.sender, pickedNumber: picked });
        FHE.allowThis(tickets[drawId][ticketId].pickedNumber);
        FHE.allow(tickets[drawId][ticketId].pickedNumber, msg.sender);
        playerTickets[drawId][msg.sender].push(ticketId);

        d.prizePool = FHE.add(d.prizePool, FHE.asEuint64(ticketPriceUSD));
        FHE.allowThis(d.prizePool);
        emit TicketPurchased(drawId, msg.sender, ticketId);
    }

    function performDraw(uint256 drawId) external onlyOwner {
        Draw storage d = draws[drawId];
        require(block.timestamp > d.closeTime, "Not closed");
        require(!d.drawn, "Done");
        euint8 rand = FHE.randEuint8();
        d.winningNumber = FHE.add(FHE.rem(rand, FHE.asEuint8(100)), FHE.asEuint8(1));
        FHE.allowThis(d.winningNumber);
        d.drawn = true;
        emit NumberDrawn(drawId);
    }

    function claimPrize(uint256 drawId, uint256 ticketId) external nonReentrant {
        Draw storage d = draws[drawId];
        require(d.drawn, "Not drawn");
        Ticket storage t = tickets[drawId][ticketId];
        require(t.owner == msg.sender, "Not your ticket");

        ebool isWinner = FHE.eq(t.pickedNumber, d.winningNumber);
        euint64 payout = FHE.select(isWinner, d.prizePool, FHE.asEuint64(0));
        FHE.allowTransient(payout, msg.sender);
        emit WinnerPaid(drawId, msg.sender);
    }
}
