// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameEncryptedFantasyLeague
/// @notice Fantasy sports league where player stats and team compositions are encrypted.
///         Managers draft players privately; scoring is computed from encrypted stats.
contract GameEncryptedFantasyLeague is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Player {
        string name;
        string position;
        euint16 attackRating;
        euint16 defenseRating;
        euint16 fitnessRating;
        bool available;
    }

    struct Team {
        string name;
        uint256[] playerIds;
        euint32 totalScore;
        euint64 prizeEarned;
        bool active;
    }

    struct Season {
        string name;
        uint256 gameweek;
        bool active;
        euint64 prizePool;
    }

    mapping(uint256 => Player) private players;
    uint256 public playerCount;
    mapping(address => Team) private teams;
    address[] public managers;
    Season private currentSeason;
    euint64 private _entryFee;

    event PlayerAdded(uint256 indexed id, string name);
    event TeamRegistered(address indexed manager, string teamName);
    event PlayerDrafted(address indexed manager, uint256 playerId);
    event ScoresUpdated(uint256 gameweek);

    constructor(externalEuint64 encEntryFee, bytes memory proof) Ownable(msg.sender) {
        _entryFee = FHE.fromExternal(encEntryFee, proof);
        currentSeason.prizePool = FHE.asEuint64(0);
        FHE.allowThis(_entryFee);
        FHE.allowThis(currentSeason.prizePool);
    }

    function addPlayer(
        string calldata name, string calldata position,
        externalEuint16 encAtk, bytes calldata aProof,
        externalEuint16 encDef, bytes calldata dProof,
        externalEuint16 encFit, bytes calldata fProof
    ) external onlyOwner returns (uint256 id) {
        id = playerCount++;
        players[id].name = name;
        players[id].position = position;
        players[id].attackRating = FHE.fromExternal(encAtk, aProof);
        players[id].defenseRating = FHE.fromExternal(encDef, dProof);
        players[id].fitnessRating = FHE.fromExternal(encFit, fProof);
        players[id].available = true;
        FHE.allowThis(players[id].attackRating);
        FHE.allowThis(players[id].defenseRating);
        FHE.allowThis(players[id].fitnessRating);
        emit PlayerAdded(id, name);
    }

    function registerTeam(string calldata teamName, externalEuint64 encPayment, bytes calldata proof) external nonReentrant {
        require(!teams[msg.sender].active, "Already registered");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        ebool paidEnough = FHE.ge(payment, _entryFee);
        teams[msg.sender].name = teamName;
        teams[msg.sender].totalScore = FHE.asEuint32(0);
        teams[msg.sender].prizeEarned = FHE.asEuint64(0);
        teams[msg.sender].active = FHE.isInitialized(paidEnough);
        currentSeason.prizePool = FHE.add(currentSeason.prizePool, FHE.select(paidEnough, _entryFee, FHE.asEuint64(0)));
        FHE.allowThis(teams[msg.sender].totalScore);
        FHE.allow(teams[msg.sender].totalScore, msg.sender);
        FHE.allowThis(teams[msg.sender].prizeEarned);
        FHE.allow(teams[msg.sender].prizeEarned, msg.sender);
        FHE.allowThis(currentSeason.prizePool);
        managers.push(msg.sender);
        emit TeamRegistered(msg.sender, teamName);
    }

    function draftPlayer(uint256 playerId) external {
        require(teams[msg.sender].active, "Not registered");
        require(players[playerId].available, "Not available");
        require(teams[msg.sender].playerIds.length < 11, "Team full");
        players[playerId].available = false;
        teams[msg.sender].playerIds.push(playerId);
        emit PlayerDrafted(msg.sender, playerId);
    }

    function updateScores(address[] calldata mgrs, externalEuint32[] calldata encScores, bytes[] calldata proofs) external onlyOwner {
        require(mgrs.length == encScores.length, "Length mismatch");
        for (uint256 i = 0; i < mgrs.length; i++) {
            euint32 score = FHE.fromExternal(encScores[i], proofs[i]);
            teams[mgrs[i]].totalScore = FHE.add(teams[mgrs[i]].totalScore, score);
            FHE.allowThis(teams[mgrs[i]].totalScore);
            FHE.allow(teams[mgrs[i]].totalScore, mgrs[i]);
        }
        currentSeason.gameweek++;
        emit ScoresUpdated(currentSeason.gameweek);
    }

    function allowTeamData(address viewer) external {
        FHE.allow(teams[msg.sender].totalScore, viewer);
        FHE.allow(teams[msg.sender].prizeEarned, viewer);
    }

    function allowPlayerStats(uint256 id, address viewer) external onlyOwner {
        FHE.allow(players[id].attackRating, viewer);
        FHE.allow(players[id].fitnessRating, viewer);
    }
}
