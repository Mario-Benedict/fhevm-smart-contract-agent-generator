// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPredictionMarketDecentralized
/// @notice Decentralized prediction market: encrypted position sizes, encrypted market liquidity,
///         encrypted probability estimates from oracle network, and private market maker spreads.
contract EncryptedPredictionMarketDecentralized is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MarketOutcome { YES, NO, INVALID }
    enum MarketStatus { OPEN, CLOSED, RESOLVED, DISPUTED }

    struct PredictionMarket {
        string question;
        string category;
        euint64 totalYesStake;      // encrypted total YES stake
        euint64 totalNoStake;       // encrypted total NO stake
        euint64 liquidityPool;      // encrypted liquidity
        euint64 yesProb;            // encrypted YES probability (bps)
        euint64 marketMakerSpread;  // encrypted MM spread
        euint64 creatorFeePool;     // encrypted creator fee accrual
        uint256 resolutionDate;
        MarketOutcome outcome;
        MarketStatus status;
        address creator;
    }

    struct Position {
        uint256 marketId;
        MarketOutcome side;
        euint64 stakeUSD;           // encrypted stake amount
        euint64 potentialPayoutUSD; // encrypted potential payout
        euint64 avgEntryProb;       // encrypted average entry probability
        bool settled;
    }

    struct OracleReport {
        uint256 marketId;
        euint64 reportedProbability;// encrypted probability from oracle
        address oracle;
        uint256 reportTime;
        bool disputed;
    }

    mapping(uint256 => PredictionMarket) private markets;
    mapping(bytes32 => Position) private positions; // keccak(user, marketId, side)
    mapping(uint256 => OracleReport[]) private oracleReports;
    uint256 public marketCount;
    euint64 private _totalPlatformFees;
    mapping(address => bool) public isOracle;
    mapping(address => bool) public isResolverAdmin;

    event MarketCreated(uint256 indexed id, string question, uint256 resolutionDate);
    event PositionTaken(bytes32 indexed posKey, uint256 marketId, MarketOutcome side);
    event MarketResolved(uint256 indexed id, MarketOutcome outcome);
    event WinningsSettled(bytes32 indexed posKey, uint256 marketId);
    event OracleReported(uint256 indexed marketId, uint256 reportIdx);
    event MarketDisputed(uint256 indexed marketId);

    constructor() Ownable(msg.sender) {
        _totalPlatformFees = FHE.asEuint64(0);
        FHE.allowThis(_totalPlatformFees);
        isOracle[msg.sender] = true;
        isResolverAdmin[msg.sender] = true;
    }

    function addOracle(address o) external onlyOwner { isOracle[o] = true; }
    function addResolver(address r) external onlyOwner { isResolverAdmin[r] = true; }

    function createMarket(
        string calldata question, string calldata category,
        externalEuint64 encLiquidity, bytes calldata lProof,
        externalEuint64 encSpread, bytes calldata sProof,
        uint256 resolutionDate
    ) external returns (uint256 id) {
        euint64 liquidity = FHE.fromExternal(encLiquidity, lProof);
        euint64 spread = FHE.fromExternal(encSpread, sProof);
        id = marketCount++;
        PredictionMarket storage _s0 = markets[id];
        _s0.question = question;
        _s0.category = category;
        _s0.totalYesStake = FHE.asEuint64(0);
        _s0.totalNoStake = FHE.asEuint64(0);
        _s0.liquidityPool = liquidity;
        _s0.yesProb = FHE.asEuint64(5000);
        _s0.marketMakerSpread = spread;
        _s0.creatorFeePool = FHE.asEuint64(0);
        _s0.resolutionDate = resolutionDate;
        _s0.outcome = MarketOutcome.INVALID;
        _s0.status = MarketStatus.OPEN;
        _s0.creator = msg.sender;
        FHE.allowThis(markets[id].totalYesStake);
        FHE.allowThis(markets[id].totalNoStake);
        FHE.allowThis(markets[id].liquidityPool);
        FHE.allowThis(markets[id].yesProb);
        FHE.allowThis(markets[id].marketMakerSpread);
        FHE.allowThis(markets[id].creatorFeePool);
        emit MarketCreated(id, question, resolutionDate);
    }

    function takePosition(
        uint256 marketId, MarketOutcome side,
        externalEuint64 encStake, bytes calldata proof
    ) external nonReentrant returns (bytes32 posKey) {
        PredictionMarket storage mkt = markets[marketId];
        require(mkt.status == MarketStatus.OPEN, "Not open");
        require(block.timestamp < mkt.resolutionDate, "Expired");
        euint64 stake = FHE.fromExternal(encStake, proof);
        // Payout = stake / probability * 10000 (simplified AMM)
        euint64 prob = side == MarketOutcome.YES ? mkt.yesProb :
            FHE.sub(FHE.asEuint64(10000), mkt.yesProb);
        euint64 payout = FHE.mul(stake, FHE.asEuint64(10000)); // simplified: prob divisor omitted
        posKey = keccak256(abi.encodePacked(msg.sender, marketId, side));
        Position storage pos = positions[posKey];
        if (!FHE.isInitialized(pos.stakeUSD)) {
            pos.stakeUSD = FHE.asEuint64(0);
            pos.potentialPayoutUSD = FHE.asEuint64(0);
            pos.avgEntryProb = FHE.asEuint64(0);
            pos.marketId = marketId;
            pos.side = side;
            FHE.allowThis(pos.stakeUSD);
            FHE.allowThis(pos.potentialPayoutUSD);
            FHE.allowThis(pos.avgEntryProb);
        }
        pos.stakeUSD = FHE.add(pos.stakeUSD, stake);
        pos.potentialPayoutUSD = FHE.add(pos.potentialPayoutUSD, payout);
        if (side == MarketOutcome.YES) {
            mkt.totalYesStake = FHE.add(mkt.totalYesStake, stake);
            FHE.allowThis(mkt.totalYesStake);
        } else {
            mkt.totalNoStake = FHE.add(mkt.totalNoStake, stake);
            FHE.allowThis(mkt.totalNoStake);
        }
        // Platform fee: 1%
        euint64 fee = FHE.div(stake, 100);
        _totalPlatformFees = FHE.add(_totalPlatformFees, fee);
        FHE.allowThis(pos.stakeUSD);
        FHE.allow(pos.stakeUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalPlatformFees, msg.sender); // [acl_misconfig]
        FHE.allowThis(pos.potentialPayoutUSD);
        FHE.allow(pos.potentialPayoutUSD, msg.sender);
        FHE.allowThis(_totalPlatformFees);
        emit PositionTaken(posKey, marketId, side);
    }

    function reportOracle(
        uint256 marketId,
        externalEuint64 encProb, bytes calldata proof
    ) external returns (uint256 reportIdx) {
        require(isOracle[msg.sender], "Not oracle");
        euint64 prob = FHE.fromExternal(encProb, proof);
        reportIdx = oracleReports[marketId].length;
        oracleReports[marketId].push(OracleReport({
            marketId: marketId, reportedProbability: prob,
            oracle: msg.sender, reportTime: block.timestamp, disputed: false
        }));
        // Update market probability as moving average
        markets[marketId].yesProb = FHE.div(FHE.add(markets[marketId].yesProb, prob), 2);
        FHE.allowThis(oracleReports[marketId][reportIdx].reportedProbability);
        FHE.allowThis(markets[marketId].yesProb);
        emit OracleReported(marketId, reportIdx);
    }

    function resolveMarket(uint256 marketId, MarketOutcome outcome) external {
        require(isResolverAdmin[msg.sender], "Not resolver");
        require(block.timestamp >= markets[marketId].resolutionDate, "Too early");
        markets[marketId].outcome = outcome;
        markets[marketId].status = MarketStatus.RESOLVED;
        emit MarketResolved(marketId, outcome);
    }

    function settleWinnings(uint256 marketId, bytes32 posKey) external nonReentrant {
        PredictionMarket storage mkt = markets[marketId];
        require(mkt.status == MarketStatus.RESOLVED, "Not resolved");
        Position storage pos = positions[posKey];
        require(!pos.settled, "Already settled");
        require(pos.side == mkt.outcome, "Wrong side");
        pos.settled = true;
        FHE.allow(pos.potentialPayoutUSD, msg.sender);
        emit WinningsSettled(posKey, marketId);
    }
}
