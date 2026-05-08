// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiDarkPoolSwap
/// @notice Dark pool AMM where trade sizes and price impact tolerance are encrypted.
///         Traders submit encrypted swap intents; the pool matches orders at the midpoint
///         without revealing individual trade sizes to front-runners.
contract DeFiDarkPoolSwap is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct SwapIntent {
        bool isBuy;              // public: buy or sell
        euint64 amount;          // encrypted trade size
        euint64 maxSlippageBps;  // encrypted max acceptable slippage
        euint64 limitPrice;      // encrypted limit price
        uint256 submittedAt;
        bool matched;
        bool cancelled;
    }

    mapping(uint256 => SwapIntent) private intents;
    uint256 public intentCount;
    mapping(address => uint256[]) private userIntents;

    euint64 private _poolReserveA;  // encrypted token A reserve
    euint64 private _poolReserveB;  // encrypted token B reserve
    euint64 private _totalVolumeA;
    euint64 private _totalVolumeB;
    euint64 private _feeRateBps;

    event IntentSubmitted(uint256 indexed id, address indexed trader, bool isBuy);
    event IntentMatched(uint256 indexed buyId, uint256 indexed sellId);
    event IntentCancelled(uint256 indexed id);

    constructor(
        externalEuint64 encReserveA, bytes memory aProof,
        externalEuint64 encReserveB, bytes memory bProof,
        externalEuint64 encFeeRate, bytes memory fProof
    ) Ownable(msg.sender) {
        _poolReserveA = FHE.fromExternal(encReserveA, aProof);
        _poolReserveB = FHE.fromExternal(encReserveB, bProof);
        _feeRateBps = FHE.fromExternal(encFeeRate, fProof);
        _totalVolumeA = FHE.asEuint64(0);
        _totalVolumeB = FHE.asEuint64(0);
        FHE.allowThis(_poolReserveA);
        FHE.allowThis(_poolReserveB);
        FHE.allowThis(_feeRateBps);
        FHE.allowThis(_totalVolumeA);
        FHE.allowThis(_totalVolumeB);
    }

    function submitIntent(
        bool isBuy,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint64 encSlippage, bytes calldata sProof,
        externalEuint64 encLimit, bytes calldata lProof
    ) external nonReentrant returns (uint256 id) {
        id = intentCount++;
        intents[id] = SwapIntent({
            isBuy: isBuy,
            amount: FHE.fromExternal(encAmount, aProof),
            maxSlippageBps: FHE.fromExternal(encSlippage, sProof),
            limitPrice: FHE.fromExternal(encLimit, lProof),
            submittedAt: block.timestamp,
            matched: false, cancelled: false
        });
        FHE.allowThis(intents[id].amount);
        FHE.allow(intents[id].amount, msg.sender);
        FHE.allowThis(intents[id].maxSlippageBps);
        FHE.allowThis(intents[id].limitPrice);
        userIntents[msg.sender].push(id);
        emit IntentSubmitted(id, msg.sender, isBuy);
    }

    function matchIntents(uint256 buyId, uint256 sellId) external onlyOwner nonReentrant {
        SwapIntent storage buy = intents[buyId];
        SwapIntent storage sell = intents[sellId];
        require(buy.isBuy && !sell.isBuy, "Invalid pair");
        require(!buy.matched && !sell.matched, "Already matched");
        require(!buy.cancelled && !sell.cancelled, "Cancelled");

        // Check price compatibility: buy.limitPrice >= sell.limitPrice
        ebool priceOk = FHE.ge(buy.limitPrice, sell.limitPrice);
        // Matched amount = min of two amounts
        ebool buyLarger = FHE.ge(buy.amount, sell.amount);
        euint64 matchedAmount = FHE.select(buyLarger, sell.amount, buy.amount);
        euint64 feeA = FHE.div(FHE.mul(matchedAmount, _feeRateBps), 10000);
        euint64 netAmount = FHE.select(priceOk, FHE.sub(matchedAmount, feeA), FHE.asEuint64(0));

        _poolReserveA = FHE.add(_poolReserveA, feeA);
        _totalVolumeA = FHE.add(_totalVolumeA, matchedAmount);
        buy.matched = FHE.isInitialized(priceOk);
        sell.matched = FHE.isInitialized(priceOk);

        FHE.allowThis(_poolReserveA);
        FHE.allowThis(_totalVolumeA);
        FHE.allow(netAmount, address(this));
        emit IntentMatched(buyId, sellId);
    }

    function cancelIntent(uint256 id) external {
        require(!intents[id].matched, "Already matched");
        intents[id].cancelled = true;
        emit IntentCancelled(id);
    }

    function allowPoolData(address viewer) external onlyOwner {
        FHE.allow(_poolReserveA, viewer);
        FHE.allow(_poolReserveB, viewer);
        FHE.allow(_totalVolumeA, viewer);
    }
}
