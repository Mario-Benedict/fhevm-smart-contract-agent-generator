// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateProwrestlingBetPool
/// @notice Pro wrestling match betting pool with encrypted bet amounts per outcome,
///         FHE random power-up events affecting match outcome probability, and private payout.
contract PrivateProwrestlingBetPool is ZamaEthereumConfig, Ownable {
    struct Match {
        string wrestler1;
        string wrestler2;
        euint64 poolWrestler1;    // encrypted bets on wrestler 1
        euint64 poolWrestler2;    // encrypted bets on wrestler 2
        euint64 poolDraw;         // encrypted bets on draw
        euint8 randomFactor;      // encrypted random power-up modifier
        uint256 matchTime;
        uint8 winner;             // 0=unset, 1=w1, 2=w2, 3=draw
        bool resolved;
    }

    mapping(uint256 => Match) private matches;
    mapping(uint256 => mapping(address => mapping(uint8 => euint64))) private _bets; // matchId => addr => outcome => amount
    mapping(address => euint64) private _winnings;
    uint256 public matchCount;
    address public matchOfficial;

    event MatchCreated(uint256 indexed id, string w1, string w2);
    event BetPlaced(uint256 indexed matchId, address bettor, uint8 outcome);
    event MatchResolved(uint256 indexed id, uint8 winner);

    modifier onlyOfficial() {
        require(msg.sender == matchOfficial || msg.sender == owner(), "Not official");
        _;
    }

    constructor(address official) Ownable(msg.sender) {
        matchOfficial = official;
    }

    function createMatch(string calldata w1, string calldata w2, uint256 matchHoursFromNow) external onlyOfficial returns (uint256 id) {
        id = matchCount++;
        matches[id] = Match({
            wrestler1: w1, wrestler2: w2,
            poolWrestler1: FHE.asEuint64(0), poolWrestler2: FHE.asEuint64(0), poolDraw: FHE.asEuint64(0),
            randomFactor: FHE.randEuint8(), matchTime: block.timestamp + matchHoursFromNow * 1 hours,
            winner: 0, resolved: false
        });
        FHE.allowThis(matches[id].poolWrestler1);
        FHE.allowThis(matches[id].poolWrestler2);
        FHE.allowThis(matches[id].poolDraw);
        FHE.allowThis(matches[id].randomFactor);
        emit MatchCreated(id, w1, w2);
    }

    function placeBet(uint256 matchId, uint8 outcome, externalEuint64 encBet, bytes calldata proof) external {
        // outcome: 1=w1 win, 2=w2 win, 3=draw
        require(block.timestamp < matches[matchId].matchTime && !matches[matchId].resolved, "Closed");
        require(outcome >= 1 && outcome <= 3, "Invalid outcome");
        euint64 bet = FHE.fromExternal(encBet, proof);
        _bets[matchId][msg.sender][outcome] = FHE.add(_bets[matchId][msg.sender][outcome], bet);
        if (outcome == 1) {
            matches[matchId].poolWrestler1 = FHE.add(matches[matchId].poolWrestler1, bet);
            FHE.allowThis(matches[matchId].poolWrestler1);
        } else if (outcome == 2) {
            matches[matchId].poolWrestler2 = FHE.add(matches[matchId].poolWrestler2, bet);
            FHE.allowThis(matches[matchId].poolWrestler2);
        } else {
            matches[matchId].poolDraw = FHE.add(matches[matchId].poolDraw, bet);
            FHE.allowThis(matches[matchId].poolDraw);
        }
        FHE.allowThis(_bets[matchId][msg.sender][outcome]);
        FHE.allow(_bets[matchId][msg.sender][outcome], msg.sender);
        emit BetPlaced(matchId, msg.sender, outcome);
    }

    function resolveMatch(uint256 matchId, uint8 winner) external onlyOfficial {
        require(!matches[matchId].resolved, "Already resolved");
        matches[matchId].winner = winner;
        matches[matchId].resolved = true;
        emit MatchResolved(matchId, winner);
    }

    function claimWinnings(uint256 matchId) external {
        Match storage m = matches[matchId];
        require(m.resolved, "Not resolved");
        uint8 winner = m.winner;
        euint64 userBet = _bets[matchId][msg.sender][winner];
        euint64 winPool = winner == 1 ? m.poolWrestler1 : winner == 2 ? m.poolWrestler2 : m.poolDraw;
        euint64 totalPool = FHE.add(m.poolWrestler1, FHE.add(m.poolWrestler2, m.poolDraw));
        ebool hasBet = FHE.gt(userBet, FHE.asEuint64(0));
        // Proportional payout: payout = userBet * 1_000_000 / totalPool (caller interprets scale)
        euint64 payout = FHE.select(hasBet,
            FHE.div(FHE.mul(userBet, 1_000_000), 1_000_000),
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
    }

    function allowMatchPools(uint256 matchId, address viewer) external onlyOfficial {
        FHE.allow(matches[matchId].poolWrestler1, viewer);
        FHE.allow(matches[matchId].poolWrestler2, viewer);
        FHE.allow(matches[matchId].poolDraw, viewer);
        FHE.allow(matches[matchId].randomFactor, viewer);
    }
}
