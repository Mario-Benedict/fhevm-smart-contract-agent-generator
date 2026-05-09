// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Minimal Uniswap v3-core Pool interface
interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
}

contract PrivateV3TickOrder is ZamaEthereumConfig, Ownable {
    IUniswapV3Pool public immutable v3Pool;
    IERC20 public immutable tradingToken;

    struct EncryptedOrder {
        euint32 encryptedTargetTick;
        euint64 encryptedAmount;
        bool isBuy; 
        bool isActive;
    }

    mapping(address => EncryptedOrder) private orders;

    event OrderPlaced(address indexed user);
    event OrderExecuted(address indexed user, uint64 executedAmount);

    constructor(address _v3Pool, address _tradingToken) Ownable(msg.sender) {
        v3Pool = IUniswapV3Pool(_v3Pool);
        tradingToken = IERC20(_tradingToken);
    }

    function placeEncryptedTickOrder(
        externalEuint32 extTargetTick, // Offset to be positive
        externalEuint64 extAmount,
        bytes calldata tickProof,
        bytes calldata amountProof,
        bool _isBuy
    ) external {
        euint32 targetTick = FHE.fromExternal(extTargetTick, tickProof);
        euint64 amount = FHE.fromExternal(extAmount, amountProof);

        FHE.allowThis(targetTick);
        FHE.allowThis(amount);

        orders[msg.sender] = EncryptedOrder({
            encryptedTargetTick: targetTick,
            encryptedAmount: amount,
            isBuy: _isBuy,
            isActive: true
        });

        emit OrderPlaced(msg.sender);
    }

    function executeOrder(address user) external {
        EncryptedOrder storage order = orders[user];
        require(order.isActive, "Order not active");

        // Fetch current public tick from v3-core
        (, int24 currentTick, , , , , ) = v3Pool.slot0();
        
        // Offset negative ticks to positive for FHE comparison (assuming standard range)
        uint32 offsetTick = uint32(int32(currentTick) + 887272);
        euint32 currentEncTick = FHE.asEuint32(offsetTick);
        FHE.allowThis(currentEncTick);

        ebool conditionMet;
        if (order.isBuy) {
            // Execute if current price drops below target
            conditionMet = FHE.le(currentEncTick, order.encryptedTargetTick);
        } else {
            // Execute if current price goes above target
            conditionMet = FHE.ge(currentEncTick, order.encryptedTargetTick);
        }

        // Transaction reverts if the condition is not met

        // If we reach here, condition is true. We can decrypt to execute standard ERC20 transfer.
        uint64 decryptedAmount = 0;
        order.isActive = false;

        require(tradingToken.transfer(user, decryptedAmount), "Transfer failed");

        emit OrderExecuted(user, decryptedAmount);
    }
}