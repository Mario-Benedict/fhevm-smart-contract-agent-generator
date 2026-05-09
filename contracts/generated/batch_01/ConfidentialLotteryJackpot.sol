// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialLotteryJackpot
/// @notice Multi-draw lottery with FHE random ticket numbers,
///         encrypted jackpot accumulation, and private winner selection.
contract ConfidentialLotteryJackpot is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Draw {
        euint32 winningNumber;      // encrypted winning number
        euint64 jackpotAmount;      // encrypted jackpot at draw time
        uint256 drawTime;
        bool completed;
        address winner;
    }

    struct Ticket {
        euint32 number;             // encrypted ticket number
        uint256 drawId;
        address owner_;
        bool claimed;
    }

    mapping(uint256 => Draw) private draws;
    mapping(uint256 => Ticket) private tickets;
    mapping(uint256 => uint256[]) private drawTickets;  // drawId => ticketIds
    euint64 private _jackpot;
    euint64 private _ticketPriceEncrypted;
    uint256 public currentDrawId;
    uint256 public totalTickets;
    uint256 public drawInterval;
    uint256 public nextDrawTime;
    address public lotteryOperator;

    event DrawCreated(uint256 indexed drawId);
    event TicketPurchased(uint256 indexed ticketId, address buyer);
    event DrawCompleted(uint256 indexed drawId, address winner);

    modifier onlyOperator() {
        require(msg.sender == lotteryOperator || msg.sender == owner(), "Not operator");
        _;
    }

    constructor(
        externalEuint64 encTicketPrice, bytes memory proof,
        uint256 drawIntervalDays
    ) Ownable(msg.sender) {
        _ticketPriceEncrypted = FHE.fromExternal(encTicketPrice, proof);
        _jackpot = FHE.asEuint64(0);
        drawInterval = drawIntervalDays * 1 days;
        nextDrawTime = block.timestamp + drawInterval;
        lotteryOperator = msg.sender;
        FHE.allowThis(_ticketPriceEncrypted);
        FHE.allowThis(_jackpot);
        _createDraw();
    }

    function _createDraw() internal returns (uint256 drawId) {
        drawId = currentDrawId++;
        draws[drawId] = Draw({
            winningNumber: FHE.asEuint32(0), jackpotAmount: FHE.asEuint64(0),
            drawTime: nextDrawTime, completed: false, winner: address(0)
        });
        FHE.allowThis(draws[drawId].winningNumber);
        FHE.allowThis(draws[drawId].jackpotAmount);
        emit DrawCreated(drawId);
    }

    function buyTicket(externalEuint64 encPayment, bytes calldata proof) external nonReentrant returns (uint256 ticketId) {
        euint64 payment = FHE.fromExternal(encPayment, proof);
        ebool sufficient = FHE.ge(payment, _ticketPriceEncrypted);
        euint64 accepted = FHE.select(sufficient, _ticketPriceEncrypted, FHE.asEuint64(0));
        _jackpot = FHE.add(_jackpot, accepted);
        FHE.allowThis(_jackpot);
        // Generate encrypted random ticket number
        euint32 ticketNum = FHE.randEuint32();
        ticketId = totalTickets++;
        tickets[ticketId] = Ticket({ number: ticketNum, drawId: currentDrawId - 1, owner_: msg.sender, claimed: false });
        FHE.allowThis(tickets[ticketId].number);
        FHE.allow(tickets[ticketId].number, msg.sender);
        drawTickets[currentDrawId - 1].push(ticketId);
        emit TicketPurchased(ticketId, msg.sender);
    }

    function conductDraw() external onlyOperator {
        require(block.timestamp >= nextDrawTime, "Not time");
        uint256 drawId = currentDrawId - 1;
        Draw storage d = draws[drawId];
        require(!d.completed, "Already done");
        d.winningNumber = FHE.randEuint32();
        d.jackpotAmount = _jackpot;
        d.completed = true;
        FHE.allowThis(d.winningNumber);
        FHE.allowThis(d.jackpotAmount);
        // New draw
        nextDrawTime = block.timestamp + drawInterval;
        uint256 newDrawId = _createDraw();
        emit DrawCompleted(drawId, address(0)); // winner determined via claimPrize
    }

    function claimPrize(uint256 drawId, uint256 ticketId) external nonReentrant {
        Ticket storage t = tickets[ticketId];
        require(t.owner_ == msg.sender && t.drawId == drawId && !t.claimed, "Invalid");
        Draw storage d = draws[drawId];
        require(d.completed, "Draw not done");
        ebool isWinner = FHE.eq(t.number, d.winningNumber);
        t.claimed = true;
        if (FHE.isInitialized(isWinner) && d.winner == address(0)) {
            d.winner = msg.sender;
            _jackpot = FHE.asEuint64(0);
            FHE.allowThis(_jackpot);
            FHE.allow(d.jackpotAmount, msg.sender);
            emit DrawCompleted(drawId, msg.sender);
        }
    }

    function allowJackpot(address viewer) external onlyOperator {
        FHE.allow(_jackpot, viewer);
    }

    function allowTicketNumber(uint256 ticketId, address viewer) external {
        require(tickets[ticketId].owner_ == msg.sender, "Not owner");
        FHE.allow(tickets[ticketId].number, viewer);
    }
}
