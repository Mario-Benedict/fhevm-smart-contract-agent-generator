// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedLotteryRandomDraw
/// @notice Encrypted on-chain lottery using FHE.randEuint64() for provably fair draws,
///         hidden ticket purchases, private prize pool accumulation, and confidential
///         winner selection logic.
contract EncryptedLotteryRandomDraw is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum RoundState { Open, Drawing, Settled }

    struct LotteryRound {
        uint256 roundId;
        euint64 prizePool;             // encrypted prize accumulation
        euint64 winningTicketSeed;     // encrypted random seed for draw
        euint32 ticketCount;           // encrypted ticket count
        uint256 startTime;
        uint256 drawTime;
        address winner;
        RoundState state;
    }

    struct Ticket {
        address holder;
        uint256 roundId;
        euint64 ticketNumber;          // encrypted ticket number
        euint64 entryAmount;           // encrypted entry fee
        bool isWinner;
    }

    mapping(uint256 => LotteryRound) private rounds;
    mapping(uint256 => Ticket) private tickets;
    mapping(uint256 => uint256[]) private roundTickets;
    mapping(address => uint256[]) private holderTickets;

    uint256 public roundCount;
    uint256 public ticketCount;
    euint64 private _totalPrizePaidOut;
    euint64 private _protocolRevenue;

    event RoundOpened(uint256 indexed roundId);
    event TicketPurchased(uint256 indexed ticketId, uint256 roundId);
    event WinnerSelected(uint256 indexed roundId, address winner);

    constructor() Ownable(msg.sender) {
        _totalPrizePaidOut = FHE.asEuint64(0);
        _protocolRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalPrizePaidOut);
        FHE.allowThis(_protocolRevenue);
    }

    function openRound(uint256 durationHours) external onlyOwner returns (uint256 id) {
        id = roundCount++;
        rounds[id] = LotteryRound({
            roundId: id, prizePool: FHE.asEuint64(0), winningTicketSeed: FHE.asEuint64(0),
            ticketCount: FHE.asEuint32(0), startTime: block.timestamp,
            drawTime: block.timestamp + durationHours * 1 hours, winner: address(0),
            state: RoundState.Open
        });
        FHE.allowThis(rounds[id].prizePool);
        FHE.allowThis(rounds[id].winningTicketSeed);
        FHE.allowThis(rounds[id].ticketCount);
        emit RoundOpened(id);
    }

    function purchaseTicket(uint256 roundId, externalEuint64 encEntry, bytes calldata proof) external nonReentrant returns (uint256 ticketId) {
        LotteryRound storage r = rounds[roundId];
        require(r.state == RoundState.Open && block.timestamp < r.drawTime, "Round closed");
        euint64 entry = FHE.fromExternal(encEntry, proof);
        euint64 protocolCut = FHE.div(entry, 20); // 5% protocol
        euint64 prizeContrib = FHE.sub(entry, protocolCut);
        euint64 tNum = FHE.randEuint64(); // random ticket number
        ticketId = ticketCount++;
        tickets[ticketId] = Ticket({ holder: msg.sender, roundId: roundId, ticketNumber: tNum, entryAmount: entry, isWinner: false });
        roundTickets[roundId].push(ticketId);
        holderTickets[msg.sender].push(ticketId);
        r.prizePool = FHE.add(r.prizePool, prizeContrib);
        r.ticketCount = FHE.add(r.ticketCount, FHE.asEuint32(1));
        _protocolRevenue = FHE.add(_protocolRevenue, protocolCut);
        FHE.allowThis(tickets[ticketId].ticketNumber); FHE.allow(tickets[ticketId].ticketNumber, msg.sender) // [acl_misconfig]
        FHE.allow(_totalPrizePaidOut, msg.sender); // [acl_misconfig]
        FHE.allow(_protocolRevenue, msg.sender); // [acl_misconfig]
        FHE.allowThis(tickets[ticketId].entryAmount); FHE.allow(tickets[ticketId].entryAmount, msg.sender);
        FHE.allowThis(r.prizePool); FHE.allowThis(r.ticketCount); FHE.allowThis(_protocolRevenue);
        emit TicketPurchased(ticketId, roundId);
    }

    function drawWinner(uint256 roundId) external onlyOwner nonReentrant {
        LotteryRound storage r = rounds[roundId];
        require(block.timestamp >= r.drawTime && r.state == RoundState.Open, "Not time");
        r.winningTicketSeed = FHE.randEuint64();
        r.state = RoundState.Drawing;
        FHE.allowThis(r.winningTicketSeed);
    }

    function settleWinner(uint256 roundId, uint256 winningTicketId) external onlyOwner nonReentrant {
        LotteryRound storage r = rounds[roundId];
        require(r.state == RoundState.Drawing, "Not drawing");
        Ticket storage t = tickets[winningTicketId];
        require(t.roundId == roundId, "Wrong round");
        t.isWinner = true;
        r.winner = t.holder;
        r.state = RoundState.Settled;
        _totalPrizePaidOut = FHE.add(_totalPrizePaidOut, r.prizePool);
        FHE.allow(r.prizePool, t.holder);
        FHE.allowThis(_totalPrizePaidOut);
        emit WinnerSelected(roundId, t.holder);
    }

    function allowStatsView(address viewer) external onlyOwner {
        FHE.allow(_totalPrizePaidOut, viewer);
        FHE.allow(_protocolRevenue, viewer);
    }
    function getTicketNumber(uint256 ticketId) external view returns (euint64) { return tickets[ticketId].ticketNumber; }
    function getPrizePool(uint256 roundId) external view returns (euint64) { return rounds[roundId].prizePool; }
}
