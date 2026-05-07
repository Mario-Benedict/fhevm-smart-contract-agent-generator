// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateRacingLeague - Racing sim with encrypted lap times, hidden car stats, and prize distribution
contract PrivateRacingLeague is ZamaEthereumConfig, Ownable {
    struct Racer {
        euint16 topSpeed;        // encrypted max speed
        euint16 handling;        // encrypted handling stat
        euint64 raceWinnings;
        uint8 racesEntered;
        uint8 podiums;
        bool registered;
    }

    struct Race {
        string trackName;
        uint8 participantCount;
        euint32 fastestLapTime;  // encrypted milliseconds
        address fastestLapHolder;
        address[] participants;
        euint64 prizePool;
        bool completed;
    }

    mapping(address => Racer) private racers;
    mapping(uint256 => Race) private races;
    uint256 public raceCount;
    address public raceDirector;

    event RacerRegistered(address indexed racer);
    event RaceCreated(uint256 indexed id, string track);
    event LapTimeSubmitted(uint256 indexed id, address racer);
    event RaceFinalized(uint256 indexed id, address winner);

    modifier onlyDirector() {
        require(msg.sender == raceDirector || msg.sender == owner(), "Not director");
        _;
    }

    constructor(address director) Ownable(msg.sender) {
        raceDirector = director;
    }

    function registerRacer(address r, externalEuint16 encSpeed, bytes calldata sProof,
                           externalEuint16 encHandling, bytes calldata hProof) external onlyDirector {
        euint16 speed = FHE.fromExternal(encSpeed, sProof);
        euint16 handling = FHE.fromExternal(encHandling, hProof);
        racers[r] = Racer({ topSpeed: speed, handling: handling, raceWinnings: FHE.asEuint64(0),
            racesEntered: 0, podiums: 0, registered: true });
        FHE.allowThis(racers[r].topSpeed); FHE.allow(racers[r].topSpeed, r);
        FHE.allowThis(racers[r].handling); FHE.allow(racers[r].handling, r);
        FHE.allowThis(racers[r].raceWinnings); FHE.allow(racers[r].raceWinnings, r);
        emit RacerRegistered(r);
    }

    function createRace(string calldata track, externalEuint64 encPrize, bytes calldata proof) external onlyDirector returns (uint256 id) {
        euint64 prize = FHE.fromExternal(encPrize, proof);
        id = raceCount++;
        races[id].trackName = track;
        races[id].fastestLapTime = FHE.asEuint32(type(uint32).max);
        races[id].prizePool = prize;
        FHE.allowThis(races[id].fastestLapTime);
        FHE.allowThis(races[id].prizePool);
        emit RaceCreated(id, track);
    }

    function submitLapTime(uint256 raceId, externalEuint32 encLap, bytes calldata proof) external {
        require(racers[msg.sender].registered && !races[raceId].completed, "Invalid");
        euint32 lapTime = FHE.fromExternal(encLap, proof);
        ebool isFastest = FHE.lt(lapTime, races[raceId].fastestLapTime);
        races[raceId].fastestLapTime = FHE.select(isFastest, lapTime, races[raceId].fastestLapTime);
        if (FHE.isInitialized(isFastest)) races[raceId].fastestLapHolder = msg.sender;
        FHE.allowThis(races[raceId].fastestLapTime);
        racers[msg.sender].racesEntered++;
        emit LapTimeSubmitted(raceId, msg.sender);
    }

    function finalizeRace(uint256 raceId) external onlyDirector {
        Race storage r = races[raceId];
        require(!r.completed, "Already done");
        r.completed = true;
        address winner = r.fastestLapHolder;
        if (winner != address(0)) {
            racers[winner].raceWinnings = FHE.add(racers[winner].raceWinnings, r.prizePool);
            racers[winner].podiums++;
            FHE.allowThis(racers[winner].raceWinnings);
            FHE.allow(racers[winner].raceWinnings, winner);
            FHE.allow(r.prizePool, winner);
            emit RaceFinalized(raceId, winner);
        }
    }

    function allowRacerStats(address r, address viewer) external {
        require(msg.sender == r || msg.sender == raceDirector, "Unauthorized");
        FHE.allow(racers[r].topSpeed, viewer);
        FHE.allow(racers[r].raceWinnings, viewer);
    }

    function allowRaceResults(uint256 raceId, address viewer) external onlyDirector {
        FHE.allow(races[raceId].fastestLapTime, viewer);
        FHE.allow(races[raceId].prizePool, viewer);
    }
}
