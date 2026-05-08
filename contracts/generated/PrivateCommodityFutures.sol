// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCommodityFutures - Encrypted commodity futures with private position sizing and settlement
contract PrivateCommodityFutures is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Side { Long, Short }
    enum CommodityType { Gold, Silver, Oil, NaturalGas, Wheat, Corn }

    struct FuturesContract {
        address trader;
        CommodityType commodity;
        Side    side;
        euint64 entryPrice;
        euint64 contractSize;   // units
        euint64 marginDeposited;
        euint64 unrealizedPnL;
        uint256 expiryDate;
        bool    settled;
        bool    liquidated;
    }

    mapping(uint256 => FuturesContract) public positions;
    mapping(address => euint64)  public traderMargin;
    mapping(address => uint256[]) public traderPositions;
    mapping(CommodityType => euint64) public currentPrices;
    uint256 public positionCount;
    uint16  public maintenanceMarginBps = 500; // 5%

    event PriceUpdated(CommodityType indexed commodity);
    event PositionOpened(uint256 indexed positionId, address indexed trader);
    event PositionSettled(uint256 indexed positionId, address indexed trader);
    event PositionLiquidated(uint256 indexed positionId);
    event MarginDeposited(address indexed trader);

    constructor() Ownable(msg.sender) {}

    function depositMargin(externalEuint64 calldata encAmount, bytes calldata inputProof) external {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        traderMargin[msg.sender] = FHE.add(traderMargin[msg.sender], amount);
        FHE.allowThis(traderMargin[msg.sender]);
        FHE.allow(traderMargin[msg.sender], msg.sender);
        emit MarginDeposited(msg.sender);
    }

    function updatePrice(CommodityType commodity, externalEuint64 calldata encPrice, bytes calldata inputProof)
        external onlyOwner
    {
        currentPrices[commodity] = FHE.fromExternal(encPrice, inputProof);
        FHE.allowThis(currentPrices[commodity]);
        emit PriceUpdated(commodity);
    }

    function openPosition(
        CommodityType commodity,
        Side side,
        uint256 expiryDays,
        externalEuint64 calldata encSize,   bytes calldata sizeProof,
        externalEuint64 calldata encMargin, bytes calldata marginProof
    ) external nonReentrant returns (uint256 positionId) {
        euint64 size   = FHE.fromExternal(encSize,   sizeProof);
        euint64 margin = FHE.fromExternal(encMargin, marginProof);
        traderMargin[msg.sender] = FHE.sub(traderMargin[msg.sender], margin);
        FHE.allowThis(traderMargin[msg.sender]);
        positionId = positionCount++;
        FuturesContract storage f = positions[positionId];
        f.trader          = msg.sender;
        f.commodity       = commodity;
        f.side            = side;
        f.entryPrice      = currentPrices[commodity];
        f.contractSize    = size;
        f.marginDeposited = margin;
        f.unrealizedPnL   = FHE.asEuint64(0);
        f.expiryDate      = block.timestamp + expiryDays * 1 days;
        FHE.allowThis(f.entryPrice); FHE.allowThis(f.contractSize);
        FHE.allowThis(f.marginDeposited); FHE.allowThis(f.unrealizedPnL);
        FHE.allow(f.entryPrice, msg.sender); FHE.allow(f.contractSize, msg.sender);
        traderPositions[msg.sender].push(positionId);
        emit PositionOpened(positionId, msg.sender);
    }

    function settlePosition(uint256 positionId) external onlyOwner nonReentrant {
        FuturesContract storage f = positions[positionId];
        require(!f.settled && !f.liquidated, "Closed");
        require(block.timestamp >= f.expiryDate, "Not expired");
        f.settled = true;
        euint64 exitPrice = currentPrices[f.commodity];
        euint64 pnl;
        if (f.side == Side.Long) {
            ebool profit = FHE.gt(exitPrice, f.entryPrice);
            pnl = FHE.select(profit,
                FHE.mul(FHE.sub(exitPrice, f.entryPrice), f.contractSize),
                FHE.asEuint64(0)
            );
        } else {
            ebool profit = FHE.lt(exitPrice, f.entryPrice);
            pnl = FHE.select(profit,
                FHE.mul(FHE.sub(f.entryPrice, exitPrice), f.contractSize),
                FHE.asEuint64(0)
            );
        }
        euint64 payout = FHE.add(f.marginDeposited, pnl);
        traderMargin[f.trader] = FHE.add(traderMargin[f.trader], payout);
        FHE.allowThis(traderMargin[f.trader]);
        FHE.allow(traderMargin[f.trader], f.trader);
        emit PositionSettled(positionId, f.trader);
    }

    function liquidatePosition(uint256 positionId) external onlyOwner {
        FuturesContract storage f = positions[positionId];
        require(!f.settled && !f.liquidated, "Closed");
        f.liquidated = true;
        emit PositionLiquidated(positionId);
    }
}
