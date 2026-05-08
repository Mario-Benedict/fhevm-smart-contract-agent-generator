// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Simplified Uniswap V3 Pool Interface for TWAP
interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

contract PrivateTWAPTrigger is ZamaEthereumConfig, Ownable {
    IUniswapV3Pool public immutable uniswapV3Pool;
    IERC20 public immutable paymentToken;

    struct HiddenOrder {
        euint32 encryptedTargetTick; // Uniswap V3 uses ticks for pricing
        euint64 encryptedTradeSize;
        bool isBuyOrder; // True if trigger when price drops below tick
        bool active;
    }

    mapping(address => HiddenOrder) private orders;

    event OrderCreated(address indexed trader, bool isBuyOrder);
    event OrderTriggered(address indexed trader, uint64 executedAmount);

    constructor(address _pool, address _token) Ownable(msg.sender) {
        uniswapV3Pool = IUniswapV3Pool(_pool);
        paymentToken = IERC20(_token);
    }

    function createHiddenLimitOrder(
        externalEuint32 memory extTargetTick,
        externalEuint64 memory extTradeSize,
        bytes calldata tickProof,
        bytes calldata sizeProof,
        bool isBuy
    ) external {
        euint32 targetTick = FHE.fromExternal(extTargetTick, tickProof);
        euint64 tradeSize = FHE.fromExternal(extTradeSize, sizeProof);

        FHE.allowThis(targetTick);
        FHE.allowThis(tradeSize);

        orders[msg.sender] = HiddenOrder({
            encryptedTargetTick: targetTick,
            encryptedTradeSize: tradeSize,
            isBuyOrder: isBuy,
            active: true
        });

        emit OrderCreated(msg.sender, isBuy);
    }

    // Retrieves a basic 5-minute TWAP tick from the Uniswap V3 Pool
    function _getTWAPTick() internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 300; // 5 mins ago
        secondsAgos[1] = 0;   // now

        (int56[] memory tickCumulatives, ) = uniswapV3Pool.observe(secondsAgos);
        
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 timeWeightedAverageTick = int24(tickCumulativesDelta / 300);
        
        return timeWeightedAverageTick;
    }

    // Anyone can call this to attempt execution. Only succeeds if hidden conditions match.
    function executeIfConditionMet(address trader) external {
        HiddenOrder storage order = orders[trader];
        require(order.active, "Order inactive");

        // 1. Get Public TWAP Tick
        int24 currentTick = _getTWAPTick();
        
        // Shift tick to positive for basic euint32 comparison (assuming tick range logic is handled off-chain)
        uint32 positiveTick = uint32(int32(currentTick) + 887272); 
        euint32 encCurrentTick = FHE.asEuint32(positiveTick);
        FHE.allowThis(encCurrentTick);

        // 2. FHE Condition Check
        ebool conditionMet;
        if (order.isBuyOrder) {
            // Trigger if current price <= target
            conditionMet = FHE.le(encCurrentTick, order.encryptedTargetTick);
        } else {
            // Trigger if current price >= target
            conditionMet = FHE.ge(encCurrentTick, order.encryptedTargetTick);
        }

        // 3. Enforce Condition
        FHE.req(conditionMet);

        // 4. Execution Logic
        // Since the condition is met, we can safely decrypt the trade size to execute the actual plaintext ERC20 transfer
        uint64 sizeToTrade = FHE.decrypt(order.encryptedTradeSize);
        
        order.active = false;
        
        // Execute the physical transfer of the ERC20 payment token
        require(paymentToken.transfer(trader, sizeToTrade), "Transfer failed");

        emit OrderTriggered(trader, sizeToTrade);
    }
}