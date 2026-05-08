// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSportsBettingExchange
/// @notice Peer-to-peer sports betting exchange: encrypted bettor positions, encrypted odds,
///         encrypted matched book, and private win/loss settlement with encrypted profit attribution.
contract EncryptedSportsBettingExchange is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Sport { FOOTBALL, BASKETBALL, TENNIS, CRICKET, BASEBALL, GOLF, BOXING }
    enum BetSide { BACK, LAY }

    struct Market {
        string eventDescription;
        Sport sport;
        euint64 backOddsBps;          // encrypted back odds (scaled 10000 = 1.0x)
        euint64 layOddsBps;           // encrypted lay odds
        euint64 totalMatchedUSD;      // encrypted total matched volume
        euint64 openBackStakeUSD;     // encrypted unmatched back stake
        euint64 openLayLiabilityUSD;  // encrypted unmatched lay liability
        euint64 exchangeFeePool;      // encrypted fee collected
        uint256 eventDate;
        bool active;
        bool settled;
        bool backWon;
    }

    struct Bet {
        uint256 marketId;
        address bettor;
        BetSide side;
        euint64 stakeUSD;             // encrypted stake amount
        euint64 liabilityUSD;         // encrypted liability (for lay bets)
        euint64 matchedUSD;           // encrypted matched portion
        euint64 potentialProfitUSD;   // encrypted potential profit
        euint64 settledAmountUSD;     // encrypted settlement
        bool matched;
        bool settled;
    }

    mapping(uint256 => Market) private markets;
    mapping(uint256 => Bet[]) private bets;
    uint256 public marketCount;
    euint64 private _totalExchangeFees;
    euint64 private _totalMatchedVolume;
    mapping(address => bool) public isExchangeAdmin;
    mapping(address => bool) public isSettlementOracle;

    event MarketCreated(uint256 indexed id, string description, Sport sport);
    event BetPlaced(uint256 indexed marketId, uint256 betIdx, address bettor, BetSide side);
    event BetMatched(uint256 indexed marketId, uint256 backIdx, uint256 layIdx);
    event MarketSettled(uint256 indexed marketId, bool backWon);
    event BetSettled(uint256 indexed marketId, uint256 betIdx);

    constructor() Ownable(msg.sender) {
        _totalExchangeFees = FHE.asEuint64(0);
        _totalMatchedVolume = FHE.asEuint64(0);
        FHE.allowThis(_totalExchangeFees);
        FHE.allowThis(_totalMatchedVolume);
        isExchangeAdmin[msg.sender] = true;
        isSettlementOracle[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isExchangeAdmin[a] = true; }
    function addOracle(address o) external onlyOwner { isSettlementOracle[o] = true; }

    function createMarket(
        string calldata description, Sport sport,
        externalEuint64 encBackOdds, bytes calldata boProof,
        externalEuint64 encLayOdds, bytes calldata loProof,
        uint256 eventDate
    ) external returns (uint256 id) {
        require(isExchangeAdmin[msg.sender], "Not admin");
        euint64 backOdds = FHE.fromExternal(encBackOdds, boProof);
        euint64 layOdds = FHE.fromExternal(encLayOdds, loProof);
        id = marketCount++;
        markets[id] = Market({
            eventDescription: description, sport: sport,
            backOddsBps: backOdds, layOddsBps: layOdds,
            totalMatchedUSD: FHE.asEuint64(0), openBackStakeUSD: FHE.asEuint64(0),
            openLayLiabilityUSD: FHE.asEuint64(0), exchangeFeePool: FHE.asEuint64(0),
            eventDate: eventDate, active: true, settled: false, backWon: false
        });
        FHE.allowThis(markets[id].backOddsBps);
        FHE.allowThis(markets[id].layOddsBps);
        FHE.allowThis(markets[id].totalMatchedUSD);
        FHE.allowThis(markets[id].openBackStakeUSD);
        FHE.allowThis(markets[id].openLayLiabilityUSD);
        FHE.allowThis(markets[id].exchangeFeePool);
        emit MarketCreated(id, description, sport);
    }

    function placeBet(
        uint256 marketId, BetSide side,
        externalEuint64 encStake, bytes calldata proof
    ) external nonReentrant returns (uint256 betIdx) {
        Market storage mkt = markets[marketId];
        require(mkt.active && block.timestamp < mkt.eventDate, "Market closed");
        euint64 stake = FHE.fromExternal(encStake, proof);
        euint64 odds = side == BetSide.BACK ? mkt.backOddsBps : mkt.layOddsBps;
        // Potential profit = stake * (odds - 10000) / 10000
        euint64 profit = FHE.div(FHE.mul(stake, FHE.sub(odds, FHE.asEuint64(10000))), 10000);
        // Liability for lay = stake * (odds - 10000) / 10000
        euint64 liability = side == BetSide.LAY ? profit : FHE.asEuint64(0);
        // Exchange fee: 2% of potential profit
        euint64 fee = FHE.div(profit, 50);
        profit = FHE.sub(profit, fee);
        mkt.exchangeFeePool = FHE.add(mkt.exchangeFeePool, fee);
        _totalExchangeFees = FHE.add(_totalExchangeFees, fee);
        betIdx = bets[marketId].length;
        bets[marketId].push(Bet({
            marketId: marketId, bettor: msg.sender, side: side,
            stakeUSD: stake, liabilityUSD: liability, matchedUSD: FHE.asEuint64(0),
            potentialProfitUSD: profit, settledAmountUSD: FHE.asEuint64(0),
            matched: false, settled: false
        }));
        if (side == BetSide.BACK) {
            mkt.openBackStakeUSD = FHE.add(mkt.openBackStakeUSD, stake);
        } else {
            mkt.openLayLiabilityUSD = FHE.add(mkt.openLayLiabilityUSD, liability);
        }
        FHE.allowThis(bets[marketId][betIdx].stakeUSD);
        FHE.allowThis(bets[marketId][betIdx].liabilityUSD);
        FHE.allowThis(bets[marketId][betIdx].matchedUSD);
        FHE.allowThis(bets[marketId][betIdx].potentialProfitUSD);
        FHE.allowThis(bets[marketId][betIdx].settledAmountUSD);
        FHE.allow(bets[marketId][betIdx].stakeUSD, msg.sender);
        FHE.allow(bets[marketId][betIdx].potentialProfitUSD, msg.sender);
        FHE.allowThis(mkt.openBackStakeUSD);
        FHE.allowThis(mkt.openLayLiabilityUSD);
        FHE.allowThis(mkt.exchangeFeePool);
        FHE.allowThis(_totalExchangeFees);
        emit BetPlaced(marketId, betIdx, msg.sender, side);
    }

    function matchBets(uint256 marketId, uint256 backIdx, uint256 layIdx) external {
        require(isExchangeAdmin[msg.sender], "Not admin");
        Bet storage backBet = bets[marketId][backIdx];
        Bet storage layBet = bets[marketId][layIdx];
        require(!backBet.matched && !layBet.matched, "Already matched");
        require(backBet.side == BetSide.BACK && layBet.side == BetSide.LAY, "Wrong sides");
        euint64 matchedAmount = backBet.stakeUSD;
        backBet.matched = true;
        layBet.matched = true;
        backBet.matchedUSD = matchedAmount;
        layBet.matchedUSD = matchedAmount;
        markets[marketId].totalMatchedUSD = FHE.add(markets[marketId].totalMatchedUSD, matchedAmount);
        _totalMatchedVolume = FHE.add(_totalMatchedVolume, matchedAmount);
        FHE.allowThis(backBet.matchedUSD);
        FHE.allowThis(layBet.matchedUSD);
        FHE.allowThis(markets[marketId].totalMatchedUSD);
        FHE.allowThis(_totalMatchedVolume);
        emit BetMatched(marketId, backIdx, layIdx);
    }

    function settleMarket(uint256 marketId, bool backWon) external {
        require(isSettlementOracle[msg.sender], "Not oracle");
        Market storage mkt = markets[marketId];
        require(mkt.active && !mkt.settled, "Not settleable");
        mkt.settled = true;
        mkt.active = false;
        mkt.backWon = backWon;
        emit MarketSettled(marketId, backWon);
    }

    function settleBet(uint256 marketId, uint256 betIdx) external nonReentrant {
        Market storage mkt = markets[marketId];
        require(mkt.settled, "Market not settled");
        Bet storage bet = bets[marketId][betIdx];
        require(!bet.settled && bet.matched, "Not settleable");
        bet.settled = true;
        bool won = (mkt.backWon && bet.side == BetSide.BACK) || (!mkt.backWon && bet.side == BetSide.LAY);
        bet.settledAmountUSD = won ? FHE.add(bet.stakeUSD, bet.potentialProfitUSD) : FHE.asEuint64(0);
        FHE.allowThis(bet.settledAmountUSD);
        FHE.allow(bet.settledAmountUSD, bet.bettor);
        emit BetSettled(marketId, betIdx);
    }
}
