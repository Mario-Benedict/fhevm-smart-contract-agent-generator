// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameEncryptedBattleRoyaleStaking
/// @notice Battle royale tournament staking: encrypted entry fees, encrypted prize pool,
///         encrypted player stats, encrypted kill-per-game metrics, and blind tournament brackets.
contract GameEncryptedBattleRoyaleStaking is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Tournament {
        string name;
        euint64 entryFeeUSD;      // encrypted entry fee
        euint64 prizePoolUSD;     // encrypted total prize pool
        euint64 winnerShareBps;   // encrypted winner %
        euint64 runnerUpShareBps; // encrypted 2nd place %
        uint256 registrationClose;
        uint256 tournamentDate;
        uint8 maxPlayers;
        uint8 registeredCount;
        bool started;
        bool ended;
    }

    struct PlayerStats {
        euint64 totalKills;        // encrypted total kills
        euint64 avgSurvivalTime;   // encrypted avg survival in seconds
        euint64 winRate;           // encrypted win rate bps
        euint64 stakedBalance;     // encrypted staked amount
        euint32 gamesPlayed;
        bool registered;
    }

    mapping(uint256 => Tournament) private tournaments;
    mapping(address => PlayerStats) private players;
    mapping(uint256 => address[]) private tournamentPlayers;
    mapping(uint256 => mapping(address => bool)) private enteredTournament;
    uint256 public tournamentCount;
    euint64 private _totalStakedPool;
    mapping(address => bool) public isTournamentAdmin;

    event TournamentCreated(uint256 indexed id, string name);
    event PlayerEntered(uint256 indexed tournamentId, address player);
    event TournamentStarted(uint256 indexed tournamentId);
    event WinnersRewarded(uint256 indexed tournamentId, address winner, address runnerUp);
    event PlayerStaked(address indexed player);

    constructor() Ownable(msg.sender) {
        _totalStakedPool = FHE.asEuint64(0);
        FHE.allowThis(_totalStakedPool);
        isTournamentAdmin[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isTournamentAdmin[a] = true; }

    function registerPlayer(externalEuint64 encStake, bytes calldata proof) external {
        euint64 stake = FHE.fromExternal(encStake, proof);
        PlayerStats storage ps = players[msg.sender];
        if (!ps.registered) {
            ps.totalKills = FHE.asEuint64(0);
            ps.avgSurvivalTime = FHE.asEuint64(0);
            ps.winRate = FHE.asEuint64(0);
            ps.gamesPlayed = 0;
            ps.registered = true;
        }
        ps.stakedBalance = FHE.add(ps.stakedBalance, stake);
        _totalStakedPool = FHE.add(_totalStakedPool, stake);
        FHE.allowThis(ps.stakedBalance);
        FHE.allow(ps.stakedBalance, msg.sender);
        FHE.allowThis(ps.totalKills);
        FHE.allowThis(ps.winRate);
        FHE.allowThis(_totalStakedPool);
        emit PlayerStaked(msg.sender);
    }

    function createTournament(
        string calldata name,
        externalEuint64 encFee, bytes calldata fProof,
        externalEuint64 encWinnerShare, bytes calldata wsProof,
        uint256 regClose, uint256 date, uint8 maxPlayers
    ) external returns (uint256 id) {
        require(isTournamentAdmin[msg.sender], "Not admin");
        euint64 fee = FHE.fromExternal(encFee, fProof);
        euint64 winnerShare = FHE.fromExternal(encWinnerShare, wsProof);
        id = tournamentCount++;
        tournaments[id] = Tournament({
            name: name, entryFeeUSD: fee, prizePoolUSD: FHE.asEuint64(0),
            winnerShareBps: winnerShare,
            runnerUpShareBps: FHE.sub(FHE.asEuint64(10000), winnerShare),
            registrationClose: regClose, tournamentDate: date,
            maxPlayers: maxPlayers, registeredCount: 0, started: false, ended: false
        });
        FHE.allowThis(tournaments[id].entryFeeUSD);
        FHE.allowThis(tournaments[id].prizePoolUSD);
        FHE.allowThis(tournaments[id].winnerShareBps);
        FHE.allowThis(tournaments[id].runnerUpShareBps);
        emit TournamentCreated(id, name);
    }

    function enterTournament(uint256 tid) external nonReentrant {
        require(players[msg.sender].registered, "Not registered");
        Tournament storage t = tournaments[tid];
        require(!enteredTournament[tid][msg.sender], "Already entered");
        require(t.registeredCount < t.maxPlayers, "Full");
        require(block.timestamp < t.registrationClose, "Closed");
        // Deduct entry fee from staked balance
        ebool hasFunds = FHE.ge(players[msg.sender].stakedBalance, t.entryFeeUSD);
        players[msg.sender].stakedBalance = FHE.select(hasFunds,
            FHE.sub(players[msg.sender].stakedBalance, t.entryFeeUSD),
            players[msg.sender].stakedBalance);
        t.prizePoolUSD = FHE.add(t.prizePoolUSD, t.entryFeeUSD);
        t.registeredCount++;
        enteredTournament[tid][msg.sender] = true;
        tournamentPlayers[tid].push(msg.sender);
        FHE.allowThis(players[msg.sender].stakedBalance);
        FHE.allow(players[msg.sender].stakedBalance, msg.sender);
        FHE.allowThis(t.prizePoolUSD);
        emit PlayerEntered(tid, msg.sender);
    }

    function recordGameStats(
        address player,
        externalEuint64 encKills, bytes calldata kProof,
        externalEuint64 encSurvival, bytes calldata sProof
    ) external {
        require(isTournamentAdmin[msg.sender], "Not admin");
        PlayerStats storage ps = players[player];
        euint64 kills = FHE.fromExternal(encKills, kProof);
        euint64 survival = FHE.fromExternal(encSurvival, sProof);
        ps.totalKills = FHE.add(ps.totalKills, kills);
        ps.avgSurvivalTime = FHE.div(FHE.add(FHE.mul(ps.avgSurvivalTime, FHE.asEuint64(uint64(ps.gamesPlayed))), survival),
            FHE.asEuint64(uint64(ps.gamesPlayed + 1)));
        ps.gamesPlayed++;
        FHE.allowThis(ps.totalKills);
        FHE.allow(ps.totalKills, player);
        FHE.allowThis(ps.avgSurvivalTime);
    }

    function rewardWinners(uint256 tid, address winner, address runnerUp) external nonReentrant {
        require(isTournamentAdmin[msg.sender], "Not admin");
        Tournament storage t = tournaments[tid];
        require(!t.ended, "Already ended");
        t.ended = true;
        euint64 winnerPrize = FHE.div(FHE.mul(t.prizePoolUSD, t.winnerShareBps), 10000);
        euint64 runnerUpPrize = FHE.div(FHE.mul(t.prizePoolUSD, t.runnerUpShareBps), 10000);
        players[winner].stakedBalance = FHE.add(players[winner].stakedBalance, winnerPrize);
        players[runnerUp].stakedBalance = FHE.add(players[runnerUp].stakedBalance, runnerUpPrize);
        // Update win rates
        players[winner].winRate = FHE.add(players[winner].winRate, FHE.asEuint64(100));
        FHE.allowThis(players[winner].stakedBalance);
        FHE.allow(players[winner].stakedBalance, winner);
        FHE.allowThis(players[runnerUp].stakedBalance);
        FHE.allow(players[runnerUp].stakedBalance, runnerUp);
        FHE.allowThis(players[winner].winRate);
        emit WinnersRewarded(tid, winner, runnerUp);
    }
}
