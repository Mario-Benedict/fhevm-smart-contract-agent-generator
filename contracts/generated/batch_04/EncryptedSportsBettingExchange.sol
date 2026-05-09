// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSportsBettingExchange
/// @notice Encrypted sports betting exchange: sealed bet amounts, private odds
///         books, confidential matched position sizes, and encrypted commission
///         deductions with lay/back order matching.
contract EncryptedSportsBettingExchange is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum BetType { Back, Lay }
    enum MarketStatus { Open, Suspended, Settled }
    enum BettingOutcome { Unresolved, Win, Loss, Void }

    struct BettingMarket {
        string eventRef;
        string description;
        address settlementOracle;
        euint64 totalMatchedUSD;
        euint64 totalCommissionUSD;
        euint64 backOdds;
        euint64 layOdds;
        MarketStatus status;
        BettingOutcome outcome;
        uint256 closingTime;
    }

    struct Bet {
        uint256 marketId;
        address bettor;
        BetType betType;
        euint64 stakeUSD;
        euint64 potentialWinUSD;
        euint64 liabilityUSD;
        euint64 odds;
        bool matched;
        bool settled;
    }

    mapping(uint256 => BettingMarket) private markets;
    mapping(uint256 => Bet) private bets;

    uint256 public marketCount;
    uint256 public betCount;
    euint64 private _totalExchangeVolumeUSD;
    euint64 private _totalCommissionEarnedUSD;

    event MarketCreated(uint256 indexed id, string eventRef);
    event BetPlaced(uint256 indexed betId, uint256 marketId, BetType betType);
    event MarketSettled(uint256 indexed id, BettingOutcome outcome);

    constructor() Ownable(msg.sender) {
        _totalExchangeVolumeUSD = FHE.asEuint64(0);
        _totalCommissionEarnedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalExchangeVolumeUSD);
        FHE.allowThis(_totalCommissionEarnedUSD);
    }

    function createMarket(
        string calldata eventRef, string calldata description, address settlementOracle,
        externalEuint64 encBackOdds, bytes calldata boProof,
        externalEuint64 encLayOdds, bytes calldata loProof,
        uint256 closingHours
    ) external onlyOwner returns (uint256 id) {
        euint64 backOdds = FHE.fromExternal(encBackOdds, boProof);
        euint64 layOdds  = FHE.fromExternal(encLayOdds, loProof);
        id = marketCount++;
        markets[id].eventRef = eventRef;
        markets[id].description = description;
        markets[id].settlementOracle = settlementOracle;
        markets[id].totalMatchedUSD = FHE.asEuint64(0);
        markets[id].totalCommissionUSD = FHE.asEuint64(0);
        markets[id].backOdds = backOdds;
        markets[id].layOdds = layOdds;
        markets[id].status = MarketStatus.Open;
        markets[id].outcome = BettingOutcome.Unresolved;
        markets[id].closingTime = block.timestamp + closingHours * 1 hours;
        FHE.allowThis(markets[id].totalMatchedUSD); FHE.allowThis(markets[id].totalCommissionUSD);
        FHE.allowThis(markets[id].backOdds); FHE.allowThis(markets[id].layOdds);
        emit MarketCreated(id, eventRef);
    }

    function placeBet(uint256 marketId, BetType betType, externalEuint64 encStake, bytes calldata proof) external nonReentrant returns (uint256 betId) {
        BettingMarket storage m = markets[marketId];
        require(m.status == MarketStatus.Open && block.timestamp < m.closingTime, "Market closed");
        euint64 stake = FHE.fromExternal(encStake, proof);
        euint64 commission = FHE.div(stake, 25); // 4% commission
        euint64 netStake = FHE.sub(stake, commission);
        euint64 potentialWin = betType == BetType.Back ? FHE.mul(netStake, m.backOdds) : FHE.asEuint64(0);
        euint64 liability    = betType == BetType.Lay  ? FHE.mul(netStake, m.layOdds)  : FHE.asEuint64(0);
        euint64 oddsUsed     = betType == BetType.Back ? m.backOdds : m.layOdds;
        m.totalMatchedUSD = FHE.add(m.totalMatchedUSD, netStake);
        m.totalCommissionUSD = FHE.add(m.totalCommissionUSD, commission);
        _totalExchangeVolumeUSD = FHE.add(_totalExchangeVolumeUSD, stake);
        _totalCommissionEarnedUSD = FHE.add(_totalCommissionEarnedUSD, commission);
        betId = betCount++;
        bets[betId].marketId = marketId;
        bets[betId].bettor = msg.sender;
        bets[betId].betType = betType;
        bets[betId].stakeUSD = netStake;
        bets[betId].potentialWinUSD = potentialWin;
        bets[betId].liabilityUSD = liability;
        bets[betId].odds = oddsUsed;
        bets[betId].matched = true;
        bets[betId].settled = false;
        FHE.allowThis(bets[betId].stakeUSD); FHE.allow(bets[betId].stakeUSD, msg.sender);
        FHE.allowThis(bets[betId].potentialWinUSD); FHE.allow(bets[betId].potentialWinUSD, msg.sender);
        FHE.allowThis(bets[betId].liabilityUSD); FHE.allow(bets[betId].liabilityUSD, msg.sender);
        FHE.allowThis(bets[betId].odds);
        FHE.allowThis(m.totalMatchedUSD); FHE.allowThis(m.totalCommissionUSD);
        FHE.allowThis(_totalExchangeVolumeUSD); FHE.allowThis(_totalCommissionEarnedUSD);
        emit BetPlaced(betId, marketId, betType);
    }

    function settleMarket(uint256 marketId, BettingOutcome outcome) external {
        BettingMarket storage m = markets[marketId];
        require(msg.sender == m.settlementOracle || msg.sender == owner(), "Not oracle");
        m.outcome = outcome;
        m.status = MarketStatus.Settled;
        FHE.allow(m.totalMatchedUSD, owner()); FHE.allow(m.totalCommissionUSD, owner());
        emit MarketSettled(marketId, outcome);
    }

    function allowExchangeStats(address viewer) external onlyOwner {
        FHE.allow(_totalExchangeVolumeUSD, viewer); FHE.allow(_totalCommissionEarnedUSD, viewer);
    }
}
