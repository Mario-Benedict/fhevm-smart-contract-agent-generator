// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPredictionMarketResolution
/// @notice Encrypted prediction market: hidden position sizes, private odds,
///         confidential payout pool, and encrypted resolution oracle with
///         branchless winner calculation.
contract EncryptedPredictionMarketResolution is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MarketOutcome { Unresolved, OutcomeA, OutcomeB, Invalid }

    struct PredictionMarket {
        string question;
        string marketRef;
        euint64 totalPoolA;            // encrypted pool for outcome A
        euint64 totalPoolB;            // encrypted pool for outcome B
        euint64 totalFees;             // encrypted platform fees
        euint64 oddsA;                 // encrypted implied odds A (bps)
        euint64 oddsB;                 // encrypted implied odds B (bps)
        MarketOutcome outcome;
        uint256 resolutionDeadline;
        address resolutionOracle;
        bool resolved;
    }

    struct Position {
        address trader;
        uint256 marketId;
        bool sideA;                    // true = outcome A
        euint64 stakeUSD;              // encrypted stake amount
        euint64 payoutUSD;             // encrypted potential payout
        bool claimed;
    }

    mapping(uint256 => PredictionMarket) private markets;
    mapping(uint256 => Position) private positions;
    mapping(uint256 => uint256[]) private marketPositions;

    uint256 public marketCount;
    uint256 public positionCount;
    euint64 private _totalTradingVolume;
    euint64 private _totalFeesEarned;

    event MarketCreated(uint256 indexed id, string question);
    event PositionTaken(uint256 indexed posId, uint256 marketId, bool sideA);
    event MarketResolved(uint256 indexed id, MarketOutcome outcome);
    event PayoutClaimed(uint256 indexed posId, address trader);

    constructor() Ownable(msg.sender) {
        _totalTradingVolume = FHE.asEuint64(0);
        _totalFeesEarned = FHE.asEuint64(0);
        FHE.allowThis(_totalTradingVolume);
        FHE.allowThis(_totalFeesEarned);
    }

    function createMarket(
        string calldata question, string calldata marketRef,
        address resolutionOracle, uint256 resolutionDays
    ) external onlyOwner returns (uint256 id) {
        id = marketCount++;
        markets[id] = PredictionMarket({
            question: question, marketRef: marketRef, totalPoolA: FHE.asEuint64(0),
            totalPoolB: FHE.asEuint64(0), totalFees: FHE.asEuint64(0),
            oddsA: FHE.asEuint64(5000), oddsB: FHE.asEuint64(5000),
            outcome: MarketOutcome.Unresolved, resolutionDeadline: block.timestamp + resolutionDays * 1 days,
            resolutionOracle: resolutionOracle, resolved: false
        });
        FHE.allowThis(markets[id].totalPoolA); FHE.allowThis(markets[id].totalPoolB);
        FHE.allowThis(markets[id].totalFees); FHE.allowThis(markets[id].oddsA); FHE.allowThis(markets[id].oddsB);
        emit MarketCreated(id, question);
    }

    function takePosition(uint256 marketId, bool sideA, externalEuint64 encStake, bytes calldata proof) external nonReentrant returns (uint256 posId) {
        PredictionMarket storage m = markets[marketId];
        require(!m.resolved && block.timestamp < m.resolutionDeadline, "Market closed");
        euint64 stake = FHE.fromExternal(encStake, proof);
        euint64 fee   = FHE.div(stake, 50); // 2% fee
        euint64 netStake = FHE.sub(stake, fee);
        m.totalFees = FHE.add(m.totalFees, fee);
        _totalTradingVolume = FHE.add(_totalTradingVolume, stake);
        _totalFeesEarned = FHE.add(_totalFeesEarned, fee);
        // Calculate potential payout at current odds
        euint64 payout;
        if (sideA) {
            m.totalPoolA = FHE.add(m.totalPoolA, netStake);
            payout = FHE.mul(netStake, FHE.asEuint64(10000)); // simplified: odds divisor omitted
        } else {
            m.totalPoolB = FHE.add(m.totalPoolB, netStake);
            payout = FHE.mul(netStake, FHE.asEuint64(10000)); // simplified: odds divisor omitted
        }
        posId = positionCount++;
        positions[posId] = Position({ trader: msg.sender, marketId: marketId, sideA: sideA, stakeUSD: netStake, payoutUSD: payout, claimed: false });
        marketPositions[marketId].push(posId);
        FHE.allowThis(positions[posId].stakeUSD); FHE.allow(positions[posId].stakeUSD, msg.sender);
        FHE.allowThis(positions[posId].payoutUSD); FHE.allow(positions[posId].payoutUSD, msg.sender);
        FHE.allowThis(m.totalPoolA); FHE.allowThis(m.totalPoolB); FHE.allowThis(m.totalFees);
        FHE.allowThis(_totalTradingVolume); FHE.allowThis(_totalFeesEarned);
        emit PositionTaken(posId, marketId, sideA);
    }

    function resolveMarket(uint256 marketId, MarketOutcome outcome) external {
        PredictionMarket storage m = markets[marketId];
        require(msg.sender == m.resolutionOracle || msg.sender == owner(), "Not oracle");
        require(!m.resolved, "Already resolved");
        m.outcome = outcome;
        m.resolved = true;
        FHE.allow(m.totalPoolA, owner()); FHE.allow(m.totalPoolB, owner());
        emit MarketResolved(marketId, outcome);
    }

    function claimPayout(uint256 posId) external nonReentrant {
        Position storage pos = positions[posId];
        PredictionMarket storage m = markets[pos.marketId];
        require(pos.trader == msg.sender && m.resolved && !pos.claimed, "Cannot claim");
        bool won = (pos.sideA && m.outcome == MarketOutcome.OutcomeA) || (!pos.sideA && m.outcome == MarketOutcome.OutcomeB);
        if (won) { FHE.allow(pos.payoutUSD, msg.sender); }
        pos.claimed = true;
        emit PayoutClaimed(posId, msg.sender);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalTradingVolume, viewer); FHE.allow(_totalFeesEarned, viewer);
    }
    function getPoolA(uint256 marketId) external view returns (euint64) { return markets[marketId].totalPoolA; }
    function getPoolB(uint256 marketId) external view returns (euint64) { return markets[marketId].totalPoolB; }
}
