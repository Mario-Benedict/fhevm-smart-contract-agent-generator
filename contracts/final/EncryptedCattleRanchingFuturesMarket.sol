// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedCattleRanchingFuturesMarket
/// @notice Livestock futures marketplace: encrypted cattle head counts, encrypted feed costs,
///         and encrypted futures positions for ranching operations.
contract EncryptedCattleRanchingFuturesMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CattleGrade { Choice, Select, Standard, Commercial, Utility }
    enum FuturesPosition { Long, Short }
    enum PositionStatus { Open, Closed, Liquidated, Expired }

    struct RanchRegistry {
        address rancher;
        string ranchId;
        string stateRegion;
        euint32 headCount;              // encrypted cattle count
        euint64 feedCostPerHeadUSD;    // encrypted daily feed cost
        euint64 estimatedValueUSD;     // encrypted herd value
        euint32 mortalityRateBps;      // encrypted mortality rate
        CattleGrade avgGrade;
        bool registered;
    }

    struct FuturesContract {
        uint256 ranchId;
        FuturesPosition position;
        euint32 contractedHeads;       // encrypted head count in contract
        euint64 strikePriceCentsPerCWT;// encrypted strike price (cents per hundred weight)
        euint64 currentPriceCentsPerCWT;// encrypted current market price
        euint64 marginPostedUSD;       // encrypted margin
        euint64 unrealizedPnLUSD;      // encrypted unrealized PnL
        uint256 expiryDate;
        PositionStatus status;
    }

    mapping(uint256 => RanchRegistry) private ranches;
    mapping(uint256 => FuturesContract) private futures;
    mapping(address => uint256) public addressToRanch;
    mapping(address => bool) public isCMEMember;      // exchange member
    mapping(address => bool) public isPriceOracle;

    uint256 public ranchCount;
    uint256 public futuresCount;
    euint64 private _totalOpenInterestUSD;
    euint64 private _totalMarginPostedUSD;

    event RanchRegistered(uint256 indexed id, string ranchId);
    event FuturesOpened(uint256 indexed id, FuturesPosition pos, uint256 ranchId);
    event FuturesClosed(uint256 indexed id);
    event MarginCall(uint256 indexed futuresId);

    modifier onlyOracle() {
        require(isPriceOracle[msg.sender] || msg.sender == owner(), "Not oracle");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalOpenInterestUSD = FHE.asEuint64(0);
        _totalMarginPostedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalOpenInterestUSD);
        FHE.allowThis(_totalMarginPostedUSD);
        isPriceOracle[msg.sender] = true;
    }

    function addOracle(address o) external onlyOwner { isPriceOracle[o] = true; }
    function addExchangeMember(address m) external onlyOwner { isCMEMember[m] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerRanch(
        string calldata ranchId, string calldata region, CattleGrade grade,
        externalEuint32 encHeads, bytes calldata hProof,
        externalEuint64 encFeedCost, bytes calldata fProof,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint32 encMortality, bytes calldata mProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 heads = FHE.fromExternal(encHeads, hProof);
        euint64 feedCost = FHE.fromExternal(encFeedCost, fProof);
        euint64 value = FHE.fromExternal(encValue, vProof);
        euint32 mortality = FHE.fromExternal(encMortality, mProof);
        id = ranchCount++;
        ranches[id].rancher = msg.sender;
        ranches[id].ranchId = ranchId;
        ranches[id].stateRegion = region;
        ranches[id].headCount = heads;
        ranches[id].feedCostPerHeadUSD = feedCost;
        ranches[id].estimatedValueUSD = value;
        ranches[id].mortalityRateBps = mortality;
        ranches[id].avgGrade = grade;
        ranches[id].registered = true;
        addressToRanch[msg.sender] = id;
        FHE.allowThis(ranches[id].headCount); FHE.allow(ranches[id].headCount, msg.sender);
        FHE.allowThis(ranches[id].feedCostPerHeadUSD); FHE.allow(ranches[id].feedCostPerHeadUSD, msg.sender);
        FHE.allowThis(ranches[id].estimatedValueUSD); FHE.allow(ranches[id].estimatedValueUSD, msg.sender);
        FHE.allowThis(ranches[id].mortalityRateBps);
        emit RanchRegistered(id, ranchId);
    }

    function openFutures(
        uint256 ranchId, FuturesPosition pos,
        externalEuint32 encHeads, bytes calldata hProof,
        externalEuint64 encStrike, bytes calldata sProof,
        externalEuint64 encMargin, bytes calldata mProof,
        uint256 expiryDays
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        require(isCMEMember[msg.sender], "Not CME member");
        euint32 heads = FHE.fromExternal(encHeads, hProof);
        euint64 strike = FHE.fromExternal(encStrike, sProof);
        euint64 margin = FHE.fromExternal(encMargin, mProof);
        id = futuresCount++;
        futures[id].ranchId = ranchId;
        futures[id].position = pos;
        futures[id].contractedHeads = heads;
        futures[id].strikePriceCentsPerCWT = strike;
        futures[id].currentPriceCentsPerCWT = strike;
        futures[id].marginPostedUSD = margin;
        futures[id].unrealizedPnLUSD = FHE.asEuint64(0);
        futures[id].expiryDate = block.timestamp + expiryDays * 1 days;
        futures[id].status = PositionStatus.Open;
        _totalOpenInterestUSD = FHE.add(_totalOpenInterestUSD, margin);
        _totalMarginPostedUSD = FHE.add(_totalMarginPostedUSD, margin);
        FHE.allowThis(futures[id].contractedHeads); FHE.allow(futures[id].contractedHeads, msg.sender);
        FHE.allowThis(futures[id].strikePriceCentsPerCWT); FHE.allow(futures[id].strikePriceCentsPerCWT, msg.sender);
        FHE.allowThis(futures[id].currentPriceCentsPerCWT); FHE.allow(futures[id].currentPriceCentsPerCWT, msg.sender);
        FHE.allowThis(futures[id].marginPostedUSD); FHE.allow(futures[id].marginPostedUSD, msg.sender);
        FHE.allowThis(futures[id].unrealizedPnLUSD); FHE.allow(futures[id].unrealizedPnLUSD, msg.sender);
        FHE.allowThis(_totalOpenInterestUSD);
        FHE.allowThis(_totalMarginPostedUSD);
        emit FuturesOpened(id, pos, ranchId);
    }

    function updateMarketPrice(
        uint256 futuresId,
        externalEuint64 encCurrentPrice, bytes calldata proof
    ) external onlyOracle {
        FuturesContract storage f = futures[futuresId];
        require(f.status == PositionStatus.Open, "Not open");
        euint64 current = FHE.fromExternal(encCurrentPrice, proof);
        f.currentPriceCentsPerCWT = current;
        // PnL for long: current - strike, for short: strike - current
        ebool priceUp = FHE.gt(current, f.strikePriceCentsPerCWT);
        euint64 diff = FHE.select(priceUp,
            ebool _safeSub179 = FHE.ge(current, f.strikePriceCentsPerCWT);
            FHE.select(_safeSub179, FHE.sub(current, f.strikePriceCentsPerCWT), FHE.asEuint64(0)),
            ebool _safeSub180 = FHE.ge(f.strikePriceCentsPerCWT, current);
            FHE.select(_safeSub180, FHE.sub(f.strikePriceCentsPerCWT, current), FHE.asEuint64(0)));
        ebool _safeMul43 = FHE.le(diff, FHE.asEuint64(type(uint64).max / 0));
        f.unrealizedPnLUSD = FHE.mul(diff, FHE.asEuint64(0)); // simplified
        FHE.allowThis(f.currentPriceCentsPerCWT);
        FHE.allowThis(f.unrealizedPnLUSD);
        // Check margin adequacy
        ebool marginOk = FHE.ge(f.marginPostedUSD, f.unrealizedPnLUSD);
        if (!FHE.isInitialized(marginOk)) emit MarginCall(futuresId);
    }

    function closeFutures(uint256 futuresId) external {
        FuturesContract storage f = futures[futuresId];
        require(f.status == PositionStatus.Open, "Not open");
        f.status = PositionStatus.Closed;
        ebool _safeSub181 = FHE.ge(_totalOpenInterestUSD, f.marginPostedUSD);
        _totalOpenInterestUSD = FHE.select(_safeSub181, FHE.sub(_totalOpenInterestUSD, f.marginPostedUSD), FHE.asEuint64(0));
        FHE.allowThis(_totalOpenInterestUSD);
        emit FuturesClosed(futuresId);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalOpenInterestUSD, viewer);
        FHE.allow(_totalMarginPostedUSD, viewer);
    }
}
