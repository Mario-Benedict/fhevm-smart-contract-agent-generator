// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV3Pool {
    function slot0() external view returns (uint160, int24 tick, uint16, uint16, uint16, uint8, bool);
}

contract ShieldedStopLoss is ZamaEthereumConfig {
    IUniswapV3Pool public immutable pool;
    IERC20 public immutable asset;

    struct StopLossOrder {
        euint32 encryptedStopTick; // Offset to positive
        euint64 encryptedAmount;
        bool isActive;
    }

    mapping(address => StopLossOrder) private orders;

    constructor(address _pool, address _asset) {
        pool = IUniswapV3Pool(_pool);
        asset = IERC20(_asset);
    }

    function setStopLoss(
        externalEuint32 extStopTick,
        externalEuint64 extAmount,
        bytes calldata proofTick,
        bytes calldata proofAmount
    ) external {
        euint32 stopTick = FHE.fromExternal(extStopTick, proofTick);
        euint64 amount = FHE.fromExternal(extAmount, proofAmount);
        euint64 amountWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 amountExposure = FHE.sub(amountWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        
        FHE.allowThis(stopTick);
        FHE.allowThis(amount);

        orders[msg.sender] = StopLossOrder(stopTick, amount, true);
    }

    function executeStopLoss(address user) external {
        require(orders[user].isActive, "No active order");
        
        (, int24 currentTick, , , , , ) = pool.slot0();
        uint32 positiveTick = uint32(int32(currentTick) + 887272);
        euint32 encCurrentTick = FHE.asEuint32(positiveTick);
        FHE.allowThis(encCurrentTick);

        // Trigger if current tick drops BELOW the stop tick
        ebool triggered = FHE.le(encCurrentTick, orders[user].encryptedStopTick);

        uint64 decryptAmount = 0;
        orders[user].isActive = false;

        require(asset.transfer(user, decryptAmount), "Transfer failed");
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}