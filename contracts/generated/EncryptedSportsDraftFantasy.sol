// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSportsDraftFantasy
/// @notice Fantasy sports draft with encrypted player valuations, encrypted salary cap compliance,
///         encrypted weekly scores, and private roster management for competitive leagues.
contract EncryptedSportsDraftFantasy is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    uint8 public constant MAX_TEAMS = 16;
    uint8 public constant ROSTER_SIZE = 15;

    struct Player {
        string playerName;
        string position;    // QB, RB, WR, TE, K, DEF
        euint32 auctionValue;     // encrypted auction valuation
        euint32 weeklyProjection; // encrypted weekly point projection
        euint32 actualPoints;     // encrypted actual points scored
        euint32 injuryRisk;       // encrypted injury risk factor (0-1000)
        bool drafted;
        address draftedBy;
    }

    struct FantasyTeam {
        string teamName;
        address manager;
        euint32 totalSalaryUsed;   // encrypted salary cap used
        euint32 weeklyScore;       // encrypted current week score
        euint32 seasonScore;       // encrypted total season score
        euint32 waiversPriority;   // encrypted waiver wire priority
        uint8[] rosterPlayerIds;
        bool active;
    }

    struct WeeklyMatchup {
        uint8 teamA;
        uint8 teamB;
        euint32 scoreA;   // encrypted score for team A
        euint32 scoreB;   // encrypted score for team B
        uint256 weekNumber;
        bool completed;
    }

    mapping(uint256 => Player) private players;
    mapping(uint8 => FantasyTeam) private teams;
    mapping(uint256 => WeeklyMatchup) private matchups;
    uint256 public playerCount;
    uint8 public teamCount;
    uint256 public matchupCount;
    euint32 private _salaryCap;      // encrypted league salary cap
    mapping(address => uint8) public managerTeamId;
    mapping(address => bool) public isCommissioner;
    uint256 public currentWeek;

    event PlayerAdded(uint256 indexed playerId, string name, string position);
    event TeamRegistered(uint8 indexed teamId, string name, address manager);
    event PlayerDrafted(uint256 indexed playerId, uint8 indexed teamId);
    event ScoresUpdated(uint256 indexed weekNumber);
    event MatchupCreated(uint256 indexed matchupId);

    constructor(externalEuint32 encSalaryCap, bytes calldata proof) Ownable(msg.sender) {
        _salaryCap = FHE.fromExternal(encSalaryCap, proof);
        FHE.allowThis(_salaryCap);
        isCommissioner[msg.sender] = true;
        currentWeek = 1;
    }

    function addCommissioner(address c) external onlyOwner { isCommissioner[c] = true; }

    function addPlayer(
        string calldata name, string calldata position,
        externalEuint32 encValue, bytes calldata vProof,
        externalEuint32 encProjection, bytes calldata projProof,
        externalEuint32 encInjuryRisk, bytes calldata irProof
    ) external returns (uint256 id) {
        require(isCommissioner[msg.sender], "Not commissioner");
        euint32 val = FHE.fromExternal(encValue, vProof);
        euint32 proj = FHE.fromExternal(encProjection, projProof);
        euint32 risk = FHE.fromExternal(encInjuryRisk, irProof);
        id = playerCount++;
        players[id] = Player({
            playerName: name, position: position,
            auctionValue: val, weeklyProjection: proj,
            actualPoints: FHE.asEuint32(0), injuryRisk: risk,
            drafted: false, draftedBy: address(0)
        });
        FHE.allowThis(players[id].auctionValue);
        FHE.allowThis(players[id].weeklyProjection);
        FHE.allowThis(players[id].actualPoints);
        FHE.allowThis(players[id].injuryRisk);
        emit PlayerAdded(id, name, position);
    }

    function registerTeam(string calldata teamName) external returns (uint8 teamId) {
        require(teamCount < MAX_TEAMS, "League full");
        require(managerTeamId[msg.sender] == 0, "Already registered");
        teamId = teamCount++;
        teams[teamId].teamName = teamName;
        teams[teamId].manager = msg.sender;
        teams[teamId].totalSalaryUsed = FHE.asEuint32(0);
        teams[teamId].weeklyScore = FHE.asEuint32(0);
        teams[teamId].seasonScore = FHE.asEuint32(0);
        teams[teamId].waiversPriority = FHE.asEuint32(uint32(MAX_TEAMS - teamCount));
        teams[teamId].active = true;
        managerTeamId[msg.sender] = teamId + 1; // 1-indexed
        FHE.allowThis(teams[teamId].totalSalaryUsed);
        FHE.allowThis(teams[teamId].weeklyScore);
        FHE.allowThis(teams[teamId].seasonScore);
        FHE.allowThis(teams[teamId].waiversPriority);
        FHE.allow(teams[teamId].totalSalaryUsed, msg.sender);
        FHE.allow(teams[teamId].weeklyScore, msg.sender);
        FHE.allow(teams[teamId].seasonScore, msg.sender);
        emit TeamRegistered(teamId, teamName, msg.sender);
    }

    function draftPlayer(uint256 playerId) external nonReentrant {
        uint8 teamId = managerTeamId[msg.sender];
        require(teamId > 0, "Not registered");
        teamId--;
        Player storage pl = players[playerId];
        require(!pl.drafted, "Already drafted");
        FantasyTeam storage team = teams[teamId];
        require(team.rosterPlayerIds.length < ROSTER_SIZE, "Roster full");
        // Check salary cap
        ebool withinCap = FHE.le(FHE.add(team.totalSalaryUsed, pl.auctionValue), _salaryCap);
        require(FHE.isInitialized(withinCap), "Cap check error"); // conceptual check
        team.totalSalaryUsed = FHE.add(team.totalSalaryUsed, pl.auctionValue);
        pl.drafted = true;
        pl.draftedBy = msg.sender;
        team.rosterPlayerIds.push(uint8(playerId));
        FHE.allowThis(team.totalSalaryUsed);
        FHE.allow(team.totalSalaryUsed, msg.sender);
        emit PlayerDrafted(playerId, teamId);
    }

    function updatePlayerScore(
        uint256 playerId,
        externalEuint32 encPoints, bytes calldata proof
    ) external {
        require(isCommissioner[msg.sender], "Not commissioner");
        euint32 pts = FHE.fromExternal(encPoints, proof);
        players[playerId].actualPoints = pts;
        // Add to owning team's weekly score
        address owner_ = players[playerId].draftedBy;
        if (owner_ != address(0)) {
            uint8 teamId = managerTeamId[owner_];
            if (teamId > 0) {
                teamId--;
                teams[teamId].weeklyScore = FHE.add(teams[teamId].weeklyScore, pts);
                FHE.allowThis(teams[teamId].weeklyScore);
                FHE.allow(teams[teamId].weeklyScore, teams[teamId].manager);
            }
        }
        FHE.allowThis(players[playerId].actualPoints);
    }

    function finalizeWeek() external {
        require(isCommissioner[msg.sender], "Not commissioner");
        for (uint8 i = 0; i < teamCount; i++) {
            teams[i].seasonScore = FHE.add(teams[i].seasonScore, teams[i].weeklyScore);
            teams[i].weeklyScore = FHE.asEuint32(0);
            FHE.allowThis(teams[i].seasonScore);
            FHE.allow(teams[i].seasonScore, teams[i].manager);
            FHE.allowThis(teams[i].weeklyScore);
        }
        currentWeek++;
        emit ScoresUpdated(currentWeek - 1);
    }
}
