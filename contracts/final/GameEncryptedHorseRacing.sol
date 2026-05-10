// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameEncryptedHorseRacing
/// @notice Horse racing game with encrypted horse speed stats and hidden odds.
///         Bettors place encrypted bets; race outcomes determined by encrypted
///         random speed rolls with hidden house edge.
contract GameEncryptedHorseRacing is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Horse {
        string name;
        string jockey;
        euint16 baseSpeed;    // encrypted base speed (0-100)
        euint16 stamina;      // encrypted stamina
        euint8 formRating;    // encrypted recent form (0-10)
        bool registered;
    }

    struct Race {
        string name;
        uint256[] horseIds;
        uint256 raceTime;
        bool finished;
        uint256 winnerId;
        euint64 totalPool;
    }

    struct Bet {
        uint256 horseId;
        euint64 amount;
        bool settled;
    }

    mapping(uint256 => Horse) private horses;
    uint256 public horseCount;
    mapping(uint256 => Race) private races;
    uint256 public raceCount;
    mapping(uint256 => mapping(address => Bet)) private bets;
    mapping(uint256 => mapping(address => bool)) private hasBet;
    mapping(uint256 => address[]) private bettors;
    euint64 private _houseEdgeBps;

    event HorseRegistered(uint256 indexed id, string name);
    event RaceCreated(uint256 indexed id, string name);
    event BetPlaced(uint256 indexed raceId, address indexed bettor, uint256 horseId);
    event RaceFinished(uint256 indexed raceId, uint256 winner);

    constructor(externalEuint64 encHouseEdge, bytes memory proof) Ownable(msg.sender) {
        _houseEdgeBps = FHE.fromExternal(encHouseEdge, proof);
        FHE.allowThis(_houseEdgeBps);
    }

    function registerHorse(
        string calldata name, string calldata jockey,
        externalEuint16 encSpeed, bytes calldata sProof,
        externalEuint16 encStamina, bytes calldata stProof,
        externalEuint8 encForm, bytes calldata fProof
    ) external onlyOwner returns (uint256 id) {
        id = horseCount++;
        horses[id].name = name;
        horses[id].jockey = jockey;
        horses[id].baseSpeed = FHE.fromExternal(encSpeed, sProof);
        horses[id].stamina = FHE.fromExternal(encStamina, stProof);
        horses[id].formRating = FHE.fromExternal(encForm, fProof);
        horses[id].registered = true;
        FHE.allowThis(horses[id].baseSpeed);
        FHE.allowThis(horses[id].stamina);
        FHE.allowThis(horses[id].formRating);
        emit HorseRegistered(id, name);
    }

    function createRace(string calldata name, uint256[] calldata horseIds, uint256 raceTime) external onlyOwner returns (uint256 id) {
        id = raceCount++;
        races[id].name = name;
        races[id].horseIds = horseIds;
        races[id].raceTime = raceTime;
        races[id].totalPool = FHE.asEuint64(0);
        FHE.allowThis(races[id].totalPool);
        emit RaceCreated(id, name);
    }

    function placeBet(uint256 raceId, uint256 horseId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        Race storage r = races[raceId];
        require(!r.finished && block.timestamp < r.raceTime, "Race not open");
        require(!hasBet[raceId][msg.sender], "Already bet");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        bets[raceId][msg.sender] = Bet({ horseId: horseId, amount: amount, settled: false });
        hasBet[raceId][msg.sender] = true;
        r.totalPool = FHE.add(r.totalPool, amount);
        FHE.allowThis(bets[raceId][msg.sender].amount);
        FHE.allow(bets[raceId][msg.sender].amount, msg.sender);
        FHE.allowThis(r.totalPool);
        bettors[raceId].push(msg.sender);
        emit BetPlaced(raceId, msg.sender, horseId);
    }

    function runRace(uint256 raceId, uint256 winnerId) external onlyOwner {
        Race storage r = races[raceId];
        require(!r.finished, "Already finished");
        require(block.timestamp >= r.raceTime, "Too early");
        r.finished = true;
        r.winnerId = winnerId;
        // Calculate house edge
        euint64 houseAmount = FHE.div(FHE.mul(r.totalPool, _houseEdgeBps), 10000); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 payoutPool = FHE.sub(r.totalPool, houseAmount);
        // Settle bets for winners
        uint256 winnerCount = 0;
        address[] storage bs = bettors[raceId];
        for (uint256 i = 0; i < bs.length; i++) {
            if (bets[raceId][bs[i]].horseId == winnerId) winnerCount++;
        }
        if (winnerCount > 0) {
            euint64 payoutPerWinner = FHE.div(payoutPool, uint64(winnerCount));
            for (uint256 i = 0; i < bs.length; i++) {
                Bet storage b = bets[raceId][bs[i]];
                if (b.horseId == winnerId && !b.settled) {
                    b.settled = true;
                    FHE.allow(payoutPerWinner, bs[i]);
                }
            }
        }
        FHE.allow(houseAmount, owner());
        emit RaceFinished(raceId, winnerId);
    }

    function allowHorseStats(uint256 horseId, address viewer) external onlyOwner {
        FHE.allow(horses[horseId].baseSpeed, viewer);
        FHE.allow(horses[horseId].formRating, viewer);
    }
}
