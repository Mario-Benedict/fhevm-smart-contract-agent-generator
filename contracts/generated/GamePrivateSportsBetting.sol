// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GamePrivateSportsBetting
/// @notice Sports betting pool where odds and payout multipliers are encrypted.
///         Bettors cannot see each other's positions or the total pool until settlement.
contract GamePrivateSportsBetting is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Event {
        string description;
        string[] outcomes;
        uint256 startTime;
        uint256 settleTime;
        bool settled;
        uint256 winningOutcome;
        euint64 totalPool;
        euint64 houseEdgeBps;
    }

    struct Position {
        uint256 outcomeIndex;
        euint64 amount;
        bool settled;
    }

    mapping(uint256 => Event) private events;
    uint256 public eventCount;
    mapping(uint256 => mapping(address => Position)) private positions;
    mapping(uint256 => mapping(uint256 => euint64)) private poolPerOutcome; // eventId => outcomeIdx => pool
    mapping(uint256 => address[]) private bettors;

    event EventCreated(uint256 indexed id, string description);
    event BetPlaced(uint256 indexed eventId, address bettor, uint256 outcome);
    event EventSettled(uint256 indexed id, uint256 winner);

    constructor() Ownable(msg.sender) {}

    function createEvent(
        string calldata description, string[] calldata outcomes,
        uint256 startTime, uint256 settleTime,
        externalEuint64 encHouseEdge, bytes calldata proof
    ) external onlyOwner returns (uint256 id) {
        id = eventCount++;
        events[id].description = description;
        events[id].outcomes = outcomes;
        events[id].startTime = startTime;
        events[id].settleTime = settleTime;
        events[id].houseEdgeBps = FHE.fromExternal(encHouseEdge, proof);
        events[id].totalPool = FHE.asEuint64(0);
        FHE.allowThis(events[id].houseEdgeBps);
        FHE.allowThis(events[id].totalPool);
        for (uint256 i = 0; i < outcomes.length; i++) {
            poolPerOutcome[id][i] = FHE.asEuint64(0);
            FHE.allowThis(poolPerOutcome[id][i]);
        }
        emit EventCreated(id, description);
    }

    function placeBet(
        uint256 eventId, uint256 outcomeIndex,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        Event storage e = events[eventId];
        require(block.timestamp < e.startTime, "Event started");
        require(outcomeIndex < e.outcomes.length, "Invalid outcome");
        require(positions[eventId][msg.sender].amount == FHE.asEuint64(0), "Already bet");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        positions[eventId][msg.sender] = Position({ outcomeIndex: outcomeIndex, amount: amount, settled: false });
        poolPerOutcome[eventId][outcomeIndex] = FHE.add(poolPerOutcome[eventId][outcomeIndex], amount);
        e.totalPool = FHE.add(e.totalPool, amount);
        FHE.allowThis(positions[eventId][msg.sender].amount);
        FHE.allow(positions[eventId][msg.sender].amount, msg.sender);
        FHE.allowThis(poolPerOutcome[eventId][outcomeIndex]);
        FHE.allowThis(e.totalPool);
        bettors[eventId].push(msg.sender);
        emit BetPlaced(eventId, msg.sender, outcomeIndex);
    }

    function settleEvent(uint256 eventId, uint256 winningOutcome) external onlyOwner {
        Event storage e = events[eventId];
        require(block.timestamp >= e.settleTime && !e.settled, "Cannot settle");
        e.settled = true;
        e.winningOutcome = winningOutcome;
        euint64 houseAmt = FHE.div(FHE.mul(e.totalPool, e.houseEdgeBps), 10000);
        euint64 payPool = FHE.sub(e.totalPool, houseAmt);
        euint64 winnerPool = poolPerOutcome[eventId][winningOutcome];
        address[] storage bs = bettors[eventId];
        for (uint256 i = 0; i < bs.length; i++) {
            Position storage pos = positions[eventId][bs[i]];
            if (pos.outcomeIndex == winningOutcome && !pos.settled) {
                pos.settled = true;
                // payout = bet * payPool / winnerPool
                euint64 payout = FHE.div(FHE.mul(pos.amount, payPool), winnerPool);
                FHE.allow(payout, bs[i]);
            }
        }
        FHE.allow(houseAmt, owner());
        emit EventSettled(eventId, winningOutcome);
    }

    function allowEventData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(events[id].totalPool, viewer);
    }
}
