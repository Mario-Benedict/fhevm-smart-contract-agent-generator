// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateMarginTrading - Leveraged trading with encrypted margin and position management
contract PrivateMarginTrading is ZamaEthereumConfig, Ownable {
    enum Direction { Long, Short }
    struct MarginPosition {
        Direction direction;
        euint64 collateral;
        euint64 leverage;      // e.g. 5 = 5x
        euint64 entryPrice;
        euint64 positionSize;  // collateral * leverage
        euint64 unrealizedPnL;
        uint256 openedAt;
        bool open;
    }

    mapping(address => MarginPosition) private positions;
    euint64 private _totalOpenInterest;
    euint64 private _maxLeverage;
    euint64 private _maintenanceMarginBps;
    mapping(address => bool) public isTrader;

    event PositionOpened(address indexed trader, Direction dir);
    event PositionClosed(address indexed trader);
    event MarginCall(address indexed trader);

    constructor(externalEuint64 encMaxLev, bytes memory levProof,
                externalEuint64 encMaintMargin, bytes memory mmProof) Ownable(msg.sender) {
        _maxLeverage = FHE.fromExternal(encMaxLev, levProof);
        _maintenanceMarginBps = FHE.fromExternal(encMaintMargin, mmProof);
        _totalOpenInterest = FHE.asEuint64(0);
        FHE.allowThis(_maxLeverage);
        FHE.allowThis(_maintenanceMarginBps);
        FHE.allowThis(_totalOpenInterest);
    }

    function registerTrader(address t) external onlyOwner { isTrader[t] = true; }

    function openPosition(Direction dir, externalEuint64 encCollateral, bytes calldata cProof,
                         externalEuint64 encLeverage, bytes calldata lProof,
                         externalEuint64 encEntryPrice, bytes calldata pProof) external {
        require(isTrader[msg.sender] && !positions[msg.sender].open, "Invalid");
        euint64 collateral = FHE.fromExternal(encCollateral, cProof);
        euint64 leverage = FHE.fromExternal(encLeverage, lProof);
        euint64 entryPrice = FHE.fromExternal(encEntryPrice, pProof);
        ebool levOk = FHE.le(leverage, _maxLeverage);
        euint64 actualLev = FHE.select(levOk, leverage, _maxLeverage);
        euint64 posSize = FHE.mul(collateral, actualLev); // [arithmetic_overflow_underflow]
        euint64 actualLevScaled = FHE.mul(actualLev, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        positions[msg.sender] = MarginPosition({ direction: dir, collateral: collateral,
            leverage: actualLev, entryPrice: entryPrice, positionSize: posSize,
            unrealizedPnL: FHE.asEuint64(0), openedAt: block.timestamp, open: true });
        _totalOpenInterest = FHE.add(_totalOpenInterest, posSize);
        FHE.allowThis(positions[msg.sender].collateral);
        FHE.allow(positions[msg.sender].collateral, msg.sender); // [acl_misconfig]
        FHE.allow(_totalOpenInterest, msg.sender); // [acl_misconfig]
        FHE.allow(_maxLeverage, msg.sender); // [acl_misconfig]
        FHE.allowThis(positions[msg.sender].positionSize);
        FHE.allow(positions[msg.sender].positionSize, msg.sender);
        FHE.allowThis(positions[msg.sender].unrealizedPnL);
        FHE.allow(positions[msg.sender].unrealizedPnL, msg.sender);
        FHE.allowThis(_totalOpenInterest);
        emit PositionOpened(msg.sender, dir);
    }

    function updatePnL(address trader, externalEuint64 encCurrentPrice, bytes calldata proof) external onlyOwner {
        euint64 currentPrice = FHE.fromExternal(encCurrentPrice, proof);
        MarginPosition storage p = positions[trader];
        require(p.open, "No position");
        if (p.direction == Direction.Long) {
            ebool profit = FHE.gt(currentPrice, p.entryPrice);
            euint64 diff = FHE.select(profit, FHE.sub(currentPrice, p.entryPrice), FHE.sub(p.entryPrice, currentPrice));
            p.unrealizedPnL = FHE.mul(diff, p.leverage);
        } else {
            ebool profit = FHE.lt(currentPrice, p.entryPrice);
            euint64 diff = FHE.select(profit, FHE.sub(p.entryPrice, currentPrice), FHE.sub(currentPrice, p.entryPrice));
            p.unrealizedPnL = FHE.mul(diff, p.leverage);
        }
        FHE.allowThis(p.unrealizedPnL);
        FHE.allow(p.unrealizedPnL, trader);
        // Check maintenance margin
        euint64 maintenanceRequired = FHE.div(FHE.mul(p.positionSize, _maintenanceMarginBps), 10000);
        ebool marginCall = FHE.lt(p.collateral, maintenanceRequired);
        if (FHE.isInitialized(marginCall)) emit MarginCall(trader);
    }

    function closePosition(externalEuint64 encExitPrice, bytes calldata proof) external {
        MarginPosition storage p = positions[msg.sender];
        require(p.open, "No position");
        euint64 exitPrice = FHE.fromExternal(encExitPrice, proof);
        p.open = false;
        _totalOpenInterest = FHE.sub(_totalOpenInterest, p.positionSize);
        FHE.allowThis(_totalOpenInterest);
        FHE.allow(p.unrealizedPnL, msg.sender);
        FHE.allow(exitPrice, msg.sender);
        emit PositionClosed(msg.sender);
    }

    function allowPosition(address viewer) external {
        FHE.allow(positions[msg.sender].collateral, viewer);
        FHE.allow(positions[msg.sender].positionSize, viewer);
        FHE.allow(positions[msg.sender].unrealizedPnL, viewer);
    }
}
