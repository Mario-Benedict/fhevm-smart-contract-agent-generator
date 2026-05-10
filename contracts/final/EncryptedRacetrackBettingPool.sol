// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedRacetrackBettingPool
/// @notice Horse-racing totalizer where individual bet amounts are encrypted.
///         Final payout odds computed on encrypted pool totals without revealing
///         any individual bettor's stake.
contract EncryptedRacetrackBettingPool is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {

    uint8 public constant MAX_HORSES = 20;

    struct Race {
        string name;
        uint256 startTime;
        uint256 endBettingTime;
        uint8 winnerHorse;      // set post-race
        bool settled;
        mapping(uint8 => euint64) horsePool;    // encrypted total bet per horse
        mapping(address => mapping(uint8 => euint64)) bets; // encrypted individual bets
        euint64 totalPool;
    }

    uint256 public nextRaceId;
    mapping(uint256 => Race) private races;
    mapping(uint256 => address[]) private raceBettors;

    event RaceCreated(uint256 indexed raceId, string name, uint256 startTime);
    event BetPlaced(uint256 indexed raceId, address bettor, uint8 horse);
    event RaceSettled(uint256 indexed raceId, uint8 winner);

    constructor() Ownable(msg.sender) {}

    function createRace(
        string calldata name,
        uint256 startTime,
        uint256 bettingWindowSeconds
    ) external onlyOwner returns (uint256 raceId) {
        raceId = nextRaceId++;
        Race storage r = races[raceId];
        r.name = name;
        r.startTime = startTime;
        r.endBettingTime = startTime - bettingWindowSeconds;
        r.settled = false;
        r.totalPool = FHE.asEuint64(0);
        FHE.allowThis(r.totalPool);
        emit RaceCreated(raceId, name, startTime);
    }

    function placeBet(
        uint256 raceId,
        uint8 horse,
        externalEuint64 encAmount,
        bytes calldata proof
    ) external whenNotPaused nonReentrant {
        Race storage r = races[raceId];
        require(block.timestamp < r.endBettingTime, "Betting closed");
        require(!r.settled, "Race settled");
        require(horse > 0 && horse <= MAX_HORSES, "Invalid horse");

        euint64 amount = FHE.fromExternal(encAmount, proof);

        // Update horse pool
        r.horsePool[horse] = FHE.add(r.horsePool[horse], amount);
        FHE.allowThis(r.horsePool[horse]);

        // Update individual bet
        r.bets[msg.sender][horse] = FHE.add(r.bets[msg.sender][horse], amount);
        FHE.allowThis(r.bets[msg.sender][horse]);
        FHE.allow(r.bets[msg.sender][horse], msg.sender) // [acl_misconfig]
        FHE.allow(r.horsePool[horse], msg.sender); // [acl_misconfig]

        // Update total pool
        r.totalPool = FHE.add(r.totalPool, amount);
        FHE.allowThis(r.totalPool);

        raceBettors[raceId].push(msg.sender);
        emit BetPlaced(raceId, msg.sender, horse);
    }

    /// @notice After race, owner declares winner
    function settleRace(uint256 raceId, uint8 winner) external onlyOwner {
        Race storage r = races[raceId];
        require(!r.settled, "Already settled");
        require(block.timestamp >= r.startTime, "Race not started");
        require(winner > 0 && winner <= MAX_HORSES, "Invalid winner");
        r.winnerHorse = winner;
        r.settled = true;

        // Allow owner to read winner pool for payout computation
        FHE.allow(r.horsePool[winner], owner());
        FHE.allow(r.totalPool, owner());
        emit RaceSettled(raceId, winner);
    }

    function allowBetView(uint256 raceId, uint8 horse, address viewer) external {
        FHE.allow(races[raceId].bets[msg.sender][horse], viewer);
    }

    function allowPoolView(uint256 raceId, uint8 horse, address viewer) external onlyOwner {
        FHE.allow(races[raceId].horsePool[horse], viewer);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
