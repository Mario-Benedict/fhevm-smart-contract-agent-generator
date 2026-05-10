// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCryptoDerivativesExchange
/// @notice Perpetual futures exchange: encrypted mark price, encrypted funding rate,
///         encrypted position sizes, encrypted margin balances, and confidential liquidation thresholds.
contract EncryptedCryptoDerivativesExchange is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Direction { LONG, SHORT }

    struct PerpMarket {
        string ticker;
        euint64 markPriceUSD;        // encrypted mark price (scaled 1e6)
        euint64 fundingRateBps;      // encrypted 8h funding rate
        euint64 openInterestLong;    // encrypted long open interest
        euint64 openInterestShort;   // encrypted short open interest
        euint64 insuranceFund;       // encrypted insurance fund balance
        euint32 maxLeverage;         // encrypted max leverage
        bool active;
    }

    struct Position {
        uint256 marketId;
        Direction direction;
        euint64 sizeUSD;             // encrypted notional size
        euint64 entryPrice;          // encrypted entry price
        euint64 margin;              // encrypted collateral margin
        euint64 unrealisedPnL;       // encrypted unrealised PnL
        euint64 liquidationPrice;    // encrypted liquidation threshold
        euint64 cumulativeFunding;   // encrypted funding paid/received
        bool open;
    }

    struct TraderAccount {
        euint64 totalMarginBalance;  // encrypted total margin deposited
        euint64 availableMargin;     // encrypted available for new positions
        euint64 realisedPnL;         // encrypted lifetime realised PnL
        euint64 totalFundingPaid;    // encrypted total funding paid
        bool exists;
    }

    mapping(uint256 => PerpMarket) private markets;
    mapping(bytes32 => Position) private positions; // keccak256(trader, marketId) => Position
    mapping(address => TraderAccount) private accounts;
    uint256 public marketCount;
    mapping(address => bool) public isMarketMaker;
    euint64 private _totalInsuranceFund;

    event MarketCreated(uint256 indexed id, string ticker);
    event PositionOpened(address indexed trader, uint256 indexed marketId, Direction dir);
    event PositionClosed(address indexed trader, uint256 indexed marketId);
    event PositionLiquidated(address indexed trader, uint256 indexed marketId);
    event FundingSettled(uint256 indexed marketId);
    event MarginDeposited(address indexed trader);

    constructor() Ownable(msg.sender) {
        _totalInsuranceFund = FHE.asEuint64(0);
        FHE.allowThis(_totalInsuranceFund);
        isMarketMaker[msg.sender] = true;
    }

    function addMarketMaker(address mm) external onlyOwner { isMarketMaker[mm] = true; }

    function createMarket(
        string calldata ticker,
        externalEuint64 encMarkPrice, bytes calldata mpProof,
        externalEuint64 encFundingRate, bytes calldata frProof,
        externalEuint32 encMaxLeverage, bytes calldata mlProof
    ) external returns (uint256 id) {
        require(isMarketMaker[msg.sender], "Not market maker");
        euint64 mark = FHE.fromExternal(encMarkPrice, mpProof);
        euint64 funding = FHE.fromExternal(encFundingRate, frProof);
        euint32 maxLev = FHE.fromExternal(encMaxLeverage, mlProof);
        id = marketCount++;
        markets[id] = PerpMarket({
            ticker: ticker, markPriceUSD: mark, fundingRateBps: funding,
            openInterestLong: FHE.asEuint64(0), openInterestShort: FHE.asEuint64(0),
            insuranceFund: FHE.asEuint64(0), maxLeverage: maxLev, active: true
        });
        FHE.allowThis(markets[id].markPriceUSD);
        FHE.allowThis(markets[id].fundingRateBps);
        FHE.allowThis(markets[id].openInterestLong);
        FHE.allowThis(markets[id].openInterestShort);
        FHE.allowThis(markets[id].insuranceFund);
        FHE.allowThis(markets[id].maxLeverage);
        emit MarketCreated(id, ticker);
    }

    function depositMargin(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        TraderAccount storage acc = accounts[msg.sender];
        if (!acc.exists) {
            acc.totalMarginBalance = FHE.asEuint64(0);
            acc.availableMargin = FHE.asEuint64(0);
            acc.realisedPnL = FHE.asEuint64(0);
            acc.totalFundingPaid = FHE.asEuint64(0);
            acc.exists = true;
            FHE.allowThis(acc.totalMarginBalance);
            FHE.allowThis(acc.availableMargin);
            FHE.allowThis(acc.realisedPnL);
            FHE.allowThis(acc.totalFundingPaid);
        }
        acc.totalMarginBalance = FHE.add(acc.totalMarginBalance, amount);
        acc.availableMargin = FHE.add(acc.availableMargin, amount);
        FHE.allowThis(acc.totalMarginBalance);
        FHE.allow(acc.totalMarginBalance, msg.sender);
        FHE.allowThis(acc.availableMargin);
        FHE.allow(acc.availableMargin, msg.sender);
        emit MarginDeposited(msg.sender);
    }

    function openPosition(
        uint256 marketId, Direction direction,
        externalEuint64 encSize, bytes calldata sProof,
        externalEuint64 encMargin, bytes calldata mProof
    ) external nonReentrant {
        PerpMarket storage mkt = markets[marketId];
        require(mkt.active, "Market inactive");
        require(accounts[msg.sender].exists, "No account");
        euint64 size = FHE.fromExternal(encSize, sProof);
        euint64 margin = FHE.fromExternal(encMargin, mProof);
        ebool hasMargin = FHE.le(margin, accounts[msg.sender].availableMargin);
        euint64 actualMargin = FHE.select(hasMargin, margin, accounts[msg.sender].availableMargin);
        // Liquidation price: for LONG = entryPrice * (1 - 1/leverage), SHORT = entryPrice * (1 + 1/leverage)
        euint64 liqPrice = direction == Direction.LONG ?
            FHE.div(FHE.mul(mkt.markPriceUSD, 9000), 10000) :
            FHE.div(FHE.mul(mkt.markPriceUSD, 11000), 10000);
        bytes32 posKey = keccak256(abi.encodePacked(msg.sender, marketId));
        positions[posKey].marketId = marketId;
        positions[posKey].direction = direction;
        positions[posKey].sizeUSD = size;
        positions[posKey].entryPrice = mkt.markPriceUSD;
        positions[posKey].margin = actualMargin;
        positions[posKey].unrealisedPnL = FHE.asEuint64(0);
        positions[posKey].liquidationPrice = liqPrice;
        positions[posKey].cumulativeFunding = FHE.asEuint64(0);
        positions[posKey].open = true;
        ebool _safeSub198 = FHE.ge(accounts[msg.sender].availableMargin, actualMargin);
        accounts[msg.sender].availableMargin = FHE.select(_safeSub198, FHE.sub(accounts[msg.sender].availableMargin, actualMargin), FHE.asEuint64(0));
        if (direction == Direction.LONG) {
            mkt.openInterestLong = FHE.add(mkt.openInterestLong, size);
            FHE.allowThis(mkt.openInterestLong);
        } else {
            mkt.openInterestShort = FHE.add(mkt.openInterestShort, size);
            FHE.allowThis(mkt.openInterestShort);
        }
        FHE.allowThis(positions[posKey].sizeUSD);
        FHE.allowThis(positions[posKey].entryPrice);
        FHE.allowThis(positions[posKey].margin);
        FHE.allowThis(positions[posKey].unrealisedPnL);
        FHE.allowThis(positions[posKey].liquidationPrice);
        FHE.allow(positions[posKey].margin, msg.sender);
        FHE.allow(positions[posKey].unrealisedPnL, msg.sender);
        FHE.allowThis(accounts[msg.sender].availableMargin);
        FHE.allow(accounts[msg.sender].availableMargin, msg.sender);
        emit PositionOpened(msg.sender, marketId, direction);
    }

    function closePosition(uint256 marketId) external nonReentrant {
        bytes32 posKey = keccak256(abi.encodePacked(msg.sender, marketId));
        Position storage pos = positions[posKey];
        require(pos.open, "No open position");
        PerpMarket storage mkt = markets[marketId];
        // PnL = (markPrice - entryPrice) * size / entryPrice for LONG
        euint64 pnl;
        ebool profitableClose = FHE.ge(mkt.markPriceUSD, pos.entryPrice);
        euint64 priceDiff = FHE.select(profitableClose,
            ebool _safeSub199 = FHE.ge(mkt.markPriceUSD, pos.entryPrice);
            FHE.select(_safeSub199, FHE.sub(mkt.markPriceUSD, pos.entryPrice), FHE.asEuint64(0)),
            ebool _safeSub200 = FHE.ge(pos.entryPrice, mkt.markPriceUSD);
            FHE.select(_safeSub200, FHE.sub(pos.entryPrice, mkt.markPriceUSD), FHE.asEuint64(0)));
        ebool _safeMul47 = FHE.le(priceDiff, FHE.asEuint64(type(uint32).max));
        pnl = FHE.mul(priceDiff, pos.sizeUSD); // simplified: entryPrice divisor omitted
        if (pos.direction == Direction.LONG) {
            euint64 returnAmt = FHE.select(profitableClose,
                FHE.add(pos.margin, pnl), FHE.sub(pos.margin, FHE.select(FHE.le(pnl, pos.margin), pnl, pos.margin)));
            accounts[msg.sender].availableMargin = FHE.add(accounts[msg.sender].availableMargin, returnAmt);
            FHE.allowThis(accounts[msg.sender].availableMargin);
            FHE.allow(accounts[msg.sender].availableMargin, msg.sender);
        }
        pos.open = false;
        accounts[msg.sender].realisedPnL = FHE.add(accounts[msg.sender].realisedPnL, pnl);
        FHE.allowThis(accounts[msg.sender].realisedPnL);
        FHE.allow(accounts[msg.sender].realisedPnL, msg.sender);
        emit PositionClosed(msg.sender, marketId);
    }

    function updateMarkPrice(uint256 marketId, externalEuint64 encPrice, bytes calldata proof) external {
        require(isMarketMaker[msg.sender], "Not market maker");
        markets[marketId].markPriceUSD = FHE.fromExternal(encPrice, proof);
        FHE.allowThis(markets[marketId].markPriceUSD);
    }

    function settleFunding(uint256 marketId, externalEuint64 encRate, bytes calldata proof) external {
        require(isMarketMaker[msg.sender], "Not market maker");
        markets[marketId].fundingRateBps = FHE.fromExternal(encRate, proof);
        FHE.allowThis(markets[marketId].fundingRateBps);
        emit FundingSettled(marketId);
    }
}
