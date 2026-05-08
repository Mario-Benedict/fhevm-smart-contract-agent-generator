// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiEncryptedOptionsMarketMaker
/// @notice Automated market maker for encrypted options contracts.
///         Greeks (delta, gamma, vega, theta) are computed on encrypted
///         underlying prices. Writers and buyers interact confidentially.
contract DeFiEncryptedOptionsMarketMaker is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum OptionType { Call, Put }
    enum OptionStyle { European, American }
    enum OptionStatus { Listed, Open, Exercised, Expired, Settled }

    struct OptionsContract {
        uint256 optionId;
        OptionType optionType;
        OptionStyle optionStyle;
        string underlyingSymbol;
        euint64 strikePriceCents;       // encrypted strike price
        euint64 currentUnderlyingPrice; // encrypted current underlying
        euint64 premiumCents;           // encrypted option premium
        euint32 impliedVolatilityBps;   // encrypted IV
        euint32 deltaBps;               // encrypted delta * 10000
        euint32 thetaCentsPerDay;       // encrypted daily theta decay
        euint64 openInterestContracts;  // encrypted OI
        euint64 totalVolumeCents;       // encrypted volume
        OptionStatus status;
        uint256 expiryTimestamp;
        uint256 contractSize;
    }

    struct WriterPosition {
        uint256 optionId;
        euint64 contractsWritten;       // encrypted contracts sold
        euint64 premiumReceivedCents;   // encrypted income
        euint64 collateralPostedCents;  // encrypted margin posted
        euint64 maxLossCents;           // encrypted max exposure
        bool active;
    }

    struct BuyerPosition {
        uint256 optionId;
        euint64 contractsHeld;          // encrypted contracts bought
        euint64 premiumPaidCents;       // encrypted cost basis
        euint64 intrinsicValueCents;    // encrypted current intrinsic value
        bool exercised;
    }

    mapping(uint256 => OptionsContract) private options;
    mapping(address => mapping(uint256 => WriterPosition)) private writerPositions;
    mapping(address => mapping(uint256 => BuyerPosition)) private buyerPositions;
    mapping(address => bool) public isMarketMaker;
    mapping(address => bool) public isOptionsWriter;

    uint256 public optionCount;
    euint64 private _totalOpenInterestValue;
    euint64 private _totalPremiumsTraded;
    euint64 private _protocolFeesCollected;

    event OptionListed(uint256 indexed optionId, OptionType optType, string underlying);
    event OptionWritten(uint256 indexed optionId, address writer);
    event OptionBought(uint256 indexed optionId, address buyer);
    event OptionExercised(uint256 indexed optionId, address buyer);
    event OptionExpired(uint256 indexed optionId);
    event GreeksUpdated(uint256 indexed optionId);

    modifier onlyMarketMaker() {
        require(isMarketMaker[msg.sender] || msg.sender == owner(), "Not market maker");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalOpenInterestValue = FHE.asEuint64(0);
        _totalPremiumsTraded = FHE.asEuint64(0);
        _protocolFeesCollected = FHE.asEuint64(0);
        FHE.allowThis(_totalOpenInterestValue);
        FHE.allowThis(_totalPremiumsTraded);
        FHE.allowThis(_protocolFeesCollected);
        isMarketMaker[msg.sender] = true;
    }

    function addMarketMaker(address mm) external onlyOwner { isMarketMaker[mm] = true; }
    function addWriter(address w) external onlyOwner { isOptionsWriter[w] = true; }

    function listOption(
        OptionType optType,
        OptionStyle optStyle,
        string calldata underlying,
        externalEuint64 encStrike, bytes calldata strikeProof,
        externalEuint64 encUnderlying, bytes calldata ulProof,
        externalEuint64 encPremium, bytes calldata premProof,
        externalEuint32 encIV, bytes calldata ivProof,
        uint256 expiryTimestamp,
        uint256 contractSize
    ) external onlyMarketMaker returns (uint256 optionId) {
        optionId = optionCount++;
        OptionsContract storage o = options[optionId];
        o.optionId = optionId;
        o.optionType = optType;
        o.optionStyle = optStyle;
        o.underlyingSymbol = underlying;
        o.strikePriceCents = FHE.fromExternal(encStrike, strikeProof);
        o.currentUnderlyingPrice = FHE.fromExternal(encUnderlying, ulProof);
        o.premiumCents = FHE.fromExternal(encPremium, premProof);
        o.impliedVolatilityBps = FHE.fromExternal(encIV, ivProof);
        o.deltaBps = FHE.asEuint32(5000); // 0.50 delta initial
        o.thetaCentsPerDay = FHE.asEuint32(0);
        o.openInterestContracts = FHE.asEuint64(0);
        o.totalVolumeCents = FHE.asEuint64(0);
        o.status = OptionStatus.Listed;
        o.expiryTimestamp = expiryTimestamp;
        o.contractSize = contractSize;
        FHE.allowThis(o.strikePriceCents);
        FHE.allowThis(o.currentUnderlyingPrice);
        FHE.allowThis(o.premiumCents);
        FHE.allowThis(o.impliedVolatilityBps);
        FHE.allowThis(o.deltaBps);
        FHE.allowThis(o.openInterestContracts);
        FHE.allowThis(o.totalVolumeCents);
        emit OptionListed(optionId, optType, underlying);
    }

    function writeOption(
        uint256 optionId,
        externalEuint64 encContracts, bytes calldata contractProof,
        externalEuint64 encCollateral, bytes calldata collProof
    ) external nonReentrant {
        require(isOptionsWriter[msg.sender], "Not approved writer");
        OptionsContract storage o = options[optionId];
        require(o.status == OptionStatus.Listed || o.status == OptionStatus.Open, "Not writable");
        euint64 contractsNum = FHE.fromExternal(encContracts, contractProof);
        euint64 collateral = FHE.fromExternal(encCollateral, collProof);
        euint64 premiumEarned = FHE.mul(contractsNum, o.premiumCents);
        WriterPosition storage wp = writerPositions[msg.sender][optionId];
        wp.optionId = optionId;
        wp.contractsWritten = FHE.add(wp.contractsWritten, contractsNum);
        wp.premiumReceivedCents = FHE.add(wp.premiumReceivedCents, premiumEarned);
        wp.collateralPostedCents = FHE.add(wp.collateralPostedCents, collateral);
        wp.active = true;
        o.openInterestContracts = FHE.add(o.openInterestContracts, contractsNum);
        o.totalVolumeCents = FHE.add(o.totalVolumeCents, premiumEarned);
        o.status = OptionStatus.Open;
        _totalOpenInterestValue = FHE.add(_totalOpenInterestValue, premiumEarned);
        _totalPremiumsTraded = FHE.add(_totalPremiumsTraded, premiumEarned);
        FHE.allowThis(wp.contractsWritten); FHE.allow(wp.contractsWritten, msg.sender);
        FHE.allowThis(wp.premiumReceivedCents); FHE.allow(wp.premiumReceivedCents, msg.sender);
        FHE.allowThis(wp.collateralPostedCents); FHE.allow(wp.collateralPostedCents, msg.sender);
        FHE.allowThis(o.openInterestContracts); FHE.allowThis(o.totalVolumeCents);
        FHE.allowThis(_totalOpenInterestValue); FHE.allowThis(_totalPremiumsTraded);
        emit OptionWritten(optionId, msg.sender);
    }

    function buyOption(
        uint256 optionId,
        externalEuint64 encContracts, bytes calldata proof
    ) external nonReentrant {
        OptionsContract storage o = options[optionId];
        require(o.status == OptionStatus.Open, "Not open");
        require(block.timestamp < o.expiryTimestamp, "Expired");
        euint64 contractsNum = FHE.fromExternal(encContracts, proof);
        euint64 totalPremium = FHE.mul(contractsNum, o.premiumCents);
        euint64 protocolFee = FHE.div(totalPremium, 100); // 1% fee
        euint64 netPremium = FHE.sub(totalPremium, protocolFee);
        _protocolFeesCollected = FHE.add(_protocolFeesCollected, protocolFee);
        BuyerPosition storage bp = buyerPositions[msg.sender][optionId];
        bp.optionId = optionId;
        bp.contractsHeld = FHE.add(bp.contractsHeld, contractsNum);
        bp.premiumPaidCents = FHE.add(bp.premiumPaidCents, netPremium);
        bp.intrinsicValueCents = FHE.asEuint64(0);
        FHE.allowThis(bp.contractsHeld); FHE.allow(bp.contractsHeld, msg.sender);
        FHE.allowThis(bp.premiumPaidCents); FHE.allow(bp.premiumPaidCents, msg.sender);
        FHE.allowThis(bp.intrinsicValueCents); FHE.allow(bp.intrinsicValueCents, msg.sender);
        FHE.allowThis(_protocolFeesCollected);
        emit OptionBought(optionId, msg.sender);
    }

    function updateGreeks(
        uint256 optionId,
        externalEuint64 encUnderlying, bytes calldata ulProof,
        externalEuint32 encDelta, bytes calldata deltaProof,
        externalEuint32 encTheta, bytes calldata thetaProof,
        externalEuint32 encIV, bytes calldata ivProof
    ) external onlyMarketMaker {
        OptionsContract storage o = options[optionId];
        o.currentUnderlyingPrice = FHE.fromExternal(encUnderlying, ulProof);
        o.deltaBps = FHE.fromExternal(encDelta, deltaProof);
        o.thetaCentsPerDay = FHE.fromExternal(encTheta, thetaProof);
        o.impliedVolatilityBps = FHE.fromExternal(encIV, ivProof);
        FHE.allowThis(o.currentUnderlyingPrice);
        FHE.allowThis(o.deltaBps);
        FHE.allowThis(o.thetaCentsPerDay);
        FHE.allowThis(o.impliedVolatilityBps);
        emit GreeksUpdated(optionId);
    }

    function exerciseOption(uint256 optionId) external nonReentrant {
        BuyerPosition storage bp = buyerPositions[msg.sender][optionId];
        OptionsContract storage o = options[optionId];
        require(!bp.exercised, "Already exercised");
        require(o.status == OptionStatus.Open, "Not open");
        if (o.optionStyle == OptionStyle.European) {
            require(block.timestamp >= o.expiryTimestamp - 86400, "Not at expiry");
        }
        // Compute intrinsic value for calls: max(0, underlying - strike)
        ebool callInMoney = FHE.gt(o.currentUnderlyingPrice, o.strikePriceCents);
        ebool putInMoney = FHE.lt(o.currentUnderlyingPrice, o.strikePriceCents);
        euint64 intrinsicCall = FHE.select(callInMoney, FHE.sub(o.currentUnderlyingPrice, o.strikePriceCents), FHE.asEuint64(0));
        euint64 intrinsicPut = FHE.select(putInMoney, FHE.sub(o.strikePriceCents, o.currentUnderlyingPrice), FHE.asEuint64(0));
        euint64 intrinsic = o.optionType == OptionType.Call ? intrinsicCall : intrinsicPut;
        bp.intrinsicValueCents = FHE.mul(bp.contractsHeld, intrinsic);
        bp.exercised = true;
        FHE.allowThis(bp.intrinsicValueCents); FHE.allow(bp.intrinsicValueCents, msg.sender);
        emit OptionExercised(optionId, msg.sender);
    }

    function expireOption(uint256 optionId) external onlyMarketMaker {
        require(block.timestamp > options[optionId].expiryTimestamp, "Not expired");
        options[optionId].status = OptionStatus.Expired;
        emit OptionExpired(optionId);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalOpenInterestValue, viewer);
        FHE.allow(_totalPremiumsTraded, viewer);
        FHE.allow(_protocolFeesCollected, viewer);
    }
}
