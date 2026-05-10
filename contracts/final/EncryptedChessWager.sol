// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedChessWager - Private chess match wagering with encrypted stake commitments
contract EncryptedChessWager is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MatchStatus { Pending, Active, Completed, Disputed }
    enum Outcome { Draw, WhiteWins, BlackWins }

    struct Match {
        address whitePlayer;
        address blackPlayer;
        euint64 whiteWager;
        euint64 blackWager;
        euint64 totalPot;
        bool whiteCommitted;
        bool blackCommitted;
        MatchStatus status;
        Outcome outcome;
        uint256 startTime;
        uint256 timeLimit;
        string gameHash; // IPFS CID of game record
    }

    mapping(uint256 => Match) public matches;
    mapping(address => euint64) public playerWinnings;
    uint256 public matchCount;
    uint16 public platformFeeBps = 200; // 2%

    event MatchCreated(uint256 indexed matchId, address indexed white, address indexed black);
    event WagerCommitted(uint256 indexed matchId, address indexed player);
    event MatchResulted(uint256 indexed matchId, Outcome outcome);
    event WinningsClaimed(address indexed player);

    constructor() Ownable(msg.sender) {}

    function createMatch(address blackPlayer, uint256 timeLimit)
        external
        returns (uint256 matchId)
    {
        matchId = matchCount++;
        Match storage m = matches[matchId];
        m.whitePlayer = msg.sender;
        m.blackPlayer = blackPlayer;
        m.whiteWager = FHE.asEuint64(0);
        m.blackWager = FHE.asEuint64(0);
        m.totalPot = FHE.asEuint64(0);
        m.status = MatchStatus.Pending;
        m.startTime = block.timestamp;
        m.timeLimit = timeLimit;
        FHE.allowThis(m.whiteWager);
        FHE.allowThis(m.blackWager);
        FHE.allowThis(m.totalPot);
        emit MatchCreated(matchId, msg.sender, blackPlayer);
    }

    function commitWager(uint256 matchId, externalEuint64 encWager, bytes calldata inputProof)
        external
        nonReentrant
    {
        Match storage m = matches[matchId];
        require(m.status == MatchStatus.Pending, "Not pending");
        euint64 wager = FHE.fromExternal(encWager, inputProof);

        if (msg.sender == m.whitePlayer) {
            m.whiteWager = wager;
            m.whiteCommitted = true;
            FHE.allowThis(m.whiteWager);
        } else if (msg.sender == m.blackPlayer) {
            m.blackWager = wager;
            m.blackCommitted = true;
            FHE.allowThis(m.blackWager);
        } else {
            revert("Not a player");
        }

        m.totalPot = FHE.add(m.whiteWager, m.blackWager);
        FHE.allowThis(m.totalPot);

        if (m.whiteCommitted && m.blackCommitted) {
            m.status = MatchStatus.Active;
        }
        emit WagerCommitted(matchId, msg.sender);
    }

    function submitResult(uint256 matchId, Outcome outcome, string calldata gameHash) external onlyOwner {
        Match storage m = matches[matchId];
        require(m.status == MatchStatus.Active, "Not active");
        m.outcome = outcome;
        m.gameHash = gameHash;
        m.status = MatchStatus.Completed;

        euint64 fee = FHE.div(FHE.mul(m.totalPot, FHE.asEuint64(uint64(platformFeeBps))), 10000);
        ebool _safeSub186 = FHE.ge(m.totalPot, fee);
        euint64 payout = FHE.select(_safeSub186, FHE.sub(m.totalPot, fee), FHE.asEuint64(0));

        address winner;
        if (outcome == Outcome.WhiteWins) {
            winner = m.whitePlayer;
        } else if (outcome == Outcome.BlackWins) {
            winner = m.blackPlayer;
        } else {
            euint64 half = FHE.div(payout, 2);
            playerWinnings[m.whitePlayer] = FHE.add(playerWinnings[m.whitePlayer], half);
            playerWinnings[m.blackPlayer] = FHE.add(playerWinnings[m.blackPlayer], half);
            FHE.allowThis(playerWinnings[m.whitePlayer]);
            FHE.allowThis(playerWinnings[m.blackPlayer]);
            FHE.allow(playerWinnings[m.whitePlayer], m.whitePlayer);
            FHE.allow(playerWinnings[m.blackPlayer], m.blackPlayer);
            emit MatchResulted(matchId, outcome);
            return;
        }

        playerWinnings[winner] = FHE.add(playerWinnings[winner], payout);
        FHE.allowThis(playerWinnings[winner]);
        FHE.allow(playerWinnings[winner], winner);
        emit MatchResulted(matchId, outcome);
    }

    function claimWinnings() external nonReentrant {
        euint64 amount = playerWinnings[msg.sender];
        playerWinnings[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(playerWinnings[msg.sender]);
        FHE.allowTransient(amount, msg.sender);
        emit WinningsClaimed(msg.sender);
    }
}
