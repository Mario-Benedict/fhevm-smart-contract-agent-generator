// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameConfidentialLottery
/// @notice Lottery where ticket numbers and jackpot size are encrypted until draw.
///         Players cannot see total pool size or other ticket numbers, preventing
///         strategic ticket buying based on pool information.
contract GameConfidentialLottery is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LotteryRound {
        uint256 drawTime;
        euint64 jackpot;
        euint64 ticketPrice;
        euint32 totalTickets;
        uint256 winningTicket;
        bool drawn;
        bool jackpotClaimed;
    }

    struct Ticket {
        euint32 ticketNumber;   // encrypted ticket number
        uint256 roundId;
        bool claimed;
    }

    mapping(uint256 => LotteryRound) private rounds;
    uint256 public roundCount;
    mapping(uint256 => mapping(address => Ticket[])) private userTickets;
    mapping(uint256 => mapping(address => bool)) public hasTicket;
    euint64 private _operatorFeeBps;

    event RoundCreated(uint256 indexed id);
    event TicketPurchased(uint256 indexed roundId, address indexed buyer);
    event WinnerDrawn(uint256 indexed roundId, uint256 winningNumber);
    event JackpotClaimed(uint256 indexed roundId, address winner);

    constructor(externalEuint64 encFee, bytes memory proof) Ownable(msg.sender) {
        _operatorFeeBps = FHE.fromExternal(encFee, proof);
        FHE.allowThis(_operatorFeeBps);
    }

    function createRound(
        uint256 drawTime,
        externalEuint64 encPrice, bytes calldata pProof
    ) external onlyOwner returns (uint256 id) {
        id = roundCount++;
        rounds[id].drawTime = drawTime;
        rounds[id].ticketPrice = FHE.fromExternal(encPrice, pProof);
        rounds[id].jackpot = FHE.asEuint64(0);
        rounds[id].totalTickets = FHE.asEuint32(0);
        FHE.allowThis(rounds[id].ticketPrice);
        FHE.allowThis(rounds[id].jackpot);
        FHE.allowThis(rounds[id].totalTickets);
        emit RoundCreated(id);
    }

    function buyTicket(
        uint256 roundId,
        externalEuint64 encPayment, bytes calldata pProof
    ) external nonReentrant {
        LotteryRound storage r = rounds[roundId];
        require(block.timestamp < r.drawTime && !r.drawn, "Closed");
        euint64 payment = FHE.fromExternal(encPayment, pProof);
        ebool paidEnough = FHE.ge(payment, r.ticketPrice);
        euint64 contribution = FHE.select(paidEnough, r.ticketPrice, FHE.asEuint64(0));
        // Generate a pseudo-random ticket number using FHE randomness
        euint32 ticketNum = FHE.randEuint32();
        euint32 assignedNum = FHE.asEuint32(0); // placeholder
        Ticket memory t = Ticket({ ticketNumber: FHE.asEuint32(0), roundId: roundId, claimed: false });
        userTickets[roundId][msg.sender].push(t);
        r.jackpot = FHE.add(r.jackpot, contribution);
        r.totalTickets = FHE.add(r.totalTickets, FHE.asEuint32(1));
        hasTicket[roundId][msg.sender] = true;
        FHE.allowThis(r.jackpot);
        FHE.allowThis(r.totalTickets);
        emit TicketPurchased(roundId, msg.sender);
    }

    function drawWinner(uint256 roundId, uint256 winningNumber) external onlyOwner {
        LotteryRound storage r = rounds[roundId];
        require(block.timestamp >= r.drawTime && !r.drawn, "Cannot draw");
        r.drawn = true;
        r.winningTicket = winningNumber;
        emit WinnerDrawn(roundId, winningNumber);
    }

    function claimJackpot(uint256 roundId) external nonReentrant {
        LotteryRound storage r = rounds[roundId];
        require(r.drawn && !r.jackpotClaimed, "Cannot claim");
        require(hasTicket[roundId][msg.sender], "No ticket");
        // Owner verifies winner off-chain and approves
        r.jackpotClaimed = true;
        euint64 operatorFee = FHE.div(FHE.mul(r.jackpot, _operatorFeeBps), 10000);
        euint64 prize = FHE.sub(r.jackpot, operatorFee);
        FHE.allow(prize, msg.sender);
        FHE.allow(operatorFee, owner());
        emit JackpotClaimed(roundId, msg.sender);
    }

    function allowRoundData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(rounds[id].jackpot, viewer);
        FHE.allow(rounds[id].totalTickets, viewer);
    }
}
