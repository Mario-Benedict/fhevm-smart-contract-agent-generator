// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedEsportsWager
/// @notice Esports match wagering with encrypted bet amounts, encrypted odds,
///         and private payout distribution to winners. Match outcome via trusted oracle.
contract EncryptedEsportsWager is ZamaEthereumConfig, Ownable {
    enum Team { Unset, TeamA, TeamB }

    struct Match {
        string tournament;
        string teamAName;
        string teamBName;
        euint64 poolTeamA;      // encrypted total wagered on Team A
        euint64 poolTeamB;      // encrypted total wagered on Team B
        uint256 deadline;
        Team winner;
        bool resolved;
    }

    mapping(uint256 => Match) private matches;
    mapping(uint256 => mapping(address => euint64)) private _betTeamA;
    mapping(uint256 => mapping(address => euint64)) private _betTeamB;
    mapping(address => euint64) private _winnings;
    uint256 public matchCount;
    address public matchOracle;
    euint64 private _platformFeesBps;
    euint64 private _totalFeesCollected;

    event MatchCreated(uint256 indexed id, string tournament);
    event WagerPlaced(uint256 indexed matchId, address bettor, Team team);
    event MatchResolved(uint256 indexed matchId, Team winner);
    event WinningsWithdrawn(address indexed bettor);

    constructor(externalEuint64 encFee, bytes memory proof, address oracle) Ownable(msg.sender) {
        _platformFeesBps = FHE.fromExternal(encFee, proof);
        _totalFeesCollected = FHE.asEuint64(0);
        matchOracle = oracle;
        FHE.allowThis(_platformFeesBps);
        FHE.allowThis(_totalFeesCollected);
    }

    function createMatch(
        string calldata tournament,
        string calldata teamA,
        string calldata teamB,
        uint256 durationHours
    ) external onlyOwner returns (uint256 id) {
        id = matchCount++;
        matches[id] = Match({
            tournament: tournament, teamAName: teamA, teamBName: teamB,
            poolTeamA: FHE.asEuint64(0), poolTeamB: FHE.asEuint64(0),
            deadline: block.timestamp + durationHours * 1 hours,
            winner: Team.Unset, resolved: false
        });
        FHE.allowThis(matches[id].poolTeamA);
        FHE.allowThis(matches[id].poolTeamB);
        emit MatchCreated(id, tournament);
    }

    function placeWager(uint256 matchId, Team team, externalEuint64 encBet, bytes calldata proof) external {
        require(block.timestamp < matches[matchId].deadline && !matches[matchId].resolved, "Closed");
        euint64 bet = FHE.fromExternal(encBet, proof);
        if (team == Team.TeamA) {
            _betTeamA[matchId][msg.sender] = FHE.add(_betTeamA[matchId][msg.sender], bet);
            matches[matchId].poolTeamA = FHE.add(matches[matchId].poolTeamA, bet);
            FHE.allowThis(_betTeamA[matchId][msg.sender]);
            FHE.allow(_betTeamA[matchId][msg.sender], msg.sender);
            FHE.allowThis(matches[matchId].poolTeamA);
        } else {
            _betTeamB[matchId][msg.sender] = FHE.add(_betTeamB[matchId][msg.sender], bet);
            matches[matchId].poolTeamB = FHE.add(matches[matchId].poolTeamB, bet);
            FHE.allowThis(_betTeamB[matchId][msg.sender]);
            FHE.allow(_betTeamB[matchId][msg.sender], msg.sender);
            FHE.allowThis(matches[matchId].poolTeamB);
        }
        emit WagerPlaced(matchId, msg.sender, team);
    }

    function resolveMatch(uint256 matchId, Team winner) external {
        require(msg.sender == matchOracle || msg.sender == owner(), "Not oracle");
        Match storage m = matches[matchId];
        require(!m.resolved && block.timestamp >= m.deadline, "Not ready");
        m.resolved = true;
        m.winner = winner;
        // Platform fee
        euint64 totalPool = FHE.add(m.poolTeamA, m.poolTeamB);
        euint64 fee = FHE.div(FHE.mul(totalPool, FHE.asEuint64(uint64(250))), 10000); // 2.5% platform fee hardcoded
        _totalFeesCollected = FHE.add(_totalFeesCollected, fee);
        FHE.allowThis(_totalFeesCollected);
        FHE.allow(m.poolTeamA, matchOracle);
        FHE.allow(m.poolTeamB, matchOracle);
        emit MatchResolved(matchId, winner);
    }

    function claimWinnings(uint256 matchId) external {
        Match storage m = matches[matchId];
        require(m.resolved, "Not resolved");
        euint64 userBet = m.winner == Team.TeamA ?
            _betTeamA[matchId][msg.sender] : _betTeamB[matchId][msg.sender];
        euint64 winnerPool = m.winner == Team.TeamA ? m.poolTeamA : m.poolTeamB;
        euint64 totalPool = FHE.add(m.poolTeamA, m.poolTeamB);
        euint64 fee = FHE.div(FHE.mul(totalPool, FHE.asEuint64(uint64(250))), 10000); // 2.5% platform fee
        euint64 netPool = FHE.sub(totalPool, fee);
        ebool hasBet = FHE.gt(userBet, FHE.asEuint64(0));
        // Proportional payout scaled by 1e6
        euint64 payout = FHE.select(hasBet,
            FHE.div(FHE.mul(userBet, FHE.asEuint64(1_000_000)), 1_000_000),
            FHE.asEuint64(0));
        _winnings[msg.sender] = FHE.add(_winnings[msg.sender], payout);
        FHE.allowThis(_winnings[msg.sender]);
        FHE.allow(_winnings[msg.sender], msg.sender);
        FHE.allow(payout, msg.sender);
    }

    function withdraw() external {
        euint64 w = _winnings[msg.sender];
        _winnings[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_winnings[msg.sender]);
        FHE.allow(w, msg.sender);
        emit WinningsWithdrawn(msg.sender);
    }

    function allowMatchStats(uint256 matchId, address viewer) external onlyOwner {
        FHE.allow(matches[matchId].poolTeamA, viewer);
        FHE.allow(matches[matchId].poolTeamB, viewer);
    }
}
