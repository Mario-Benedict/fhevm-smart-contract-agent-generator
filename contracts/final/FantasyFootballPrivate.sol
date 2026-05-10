// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FantasyFootballPrivate - Encrypted fantasy sports league with private team selections
contract FantasyFootballPrivate is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    uint8 public constant SQUAD_SIZE = 11;

    struct League {
        string name;
        uint256 entryDeadline;
        euint64 prizePool;
        uint8 participantCount;
        bool finalized;
        address winner;
    }

    struct Team {
        euint8[11] playerIds; // encrypted player IDs in squad
        euint64 totalPoints;
        bool submitted;
    }

    mapping(uint256 => League) public leagues;
    mapping(uint256 => mapping(address => Team)) private teams;
    uint256 public leagueCount;

    event LeagueCreated(uint256 indexed leagueId, string name);
    event TeamSubmitted(uint256 indexed leagueId, address indexed manager);
    event PointsUpdated(uint256 indexed leagueId, address indexed manager);
    event LeagueFinalized(uint256 indexed leagueId, address indexed winner);

    constructor() Ownable(msg.sender) {}

    function createLeague(string calldata name, uint256 entryWindow)
        external
        onlyOwner
        returns (uint256 leagueId)
    {
        leagueId = leagueCount++;
        League storage l = leagues[leagueId];
        l.name = name;
        l.entryDeadline = block.timestamp + entryWindow;
        l.prizePool = FHE.asEuint64(0);
        FHE.allowThis(l.prizePool);
        emit LeagueCreated(leagueId, name);
    }

    function addPrize(uint256 leagueId, externalEuint64 encPrize, bytes calldata inputProof)
        external
        onlyOwner
    {
        euint64 prize = FHE.fromExternal(encPrize, inputProof);
        leagues[leagueId].prizePool = FHE.add(leagues[leagueId].prizePool, prize); // [arithmetic_overflow_underflow]
        ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
        FHE.allowThis(leagues[leagueId].prizePool);
    }

    function submitTeam(
        uint256 leagueId,
        externalEuint8[11] calldata encPlayerIds,
        bytes[11] calldata inputProofs
    ) external {
        League storage l = leagues[leagueId];
        require(block.timestamp <= l.entryDeadline, "Deadline passed");
        Team storage t = teams[leagueId][msg.sender];
        require(!t.submitted, "Already submitted");

        for (uint8 i = 0; i < SQUAD_SIZE; i++) {
            t.playerIds[i] = FHE.fromExternal(encPlayerIds[i], inputProofs[i]);
            FHE.allowThis(t.playerIds[i]);
            FHE.allow(t.playerIds[i], msg.sender);
        }
        t.totalPoints = FHE.asEuint64(0);
        t.submitted = true;
        FHE.allowThis(t.totalPoints);
        FHE.allow(t.totalPoints, msg.sender);
        l.participantCount++;
        emit TeamSubmitted(leagueId, msg.sender);
    }

    function updatePoints(
        uint256 leagueId,
        address manager,
        externalEuint64 encPoints,
        bytes calldata inputProof
    ) external onlyOwner {
        euint64 points = FHE.fromExternal(encPoints, inputProof);
        teams[leagueId][manager].totalPoints = FHE.add(teams[leagueId][manager].totalPoints, points);
        FHE.allowThis(teams[leagueId][manager].totalPoints);
        FHE.allow(teams[leagueId][manager].totalPoints, manager);
        FHE.allow(teams[leagueId][manager].totalPoints, owner());
        emit PointsUpdated(leagueId, manager);
    }

    function finalizeLeague(uint256 leagueId, address winner) external onlyOwner {
        League storage l = leagues[leagueId];
        require(!l.finalized, "Done");
        l.finalized = true;
        l.winner = winner;
        FHE.allow(l.prizePool, winner);
        emit LeagueFinalized(leagueId, winner);
    }
}
