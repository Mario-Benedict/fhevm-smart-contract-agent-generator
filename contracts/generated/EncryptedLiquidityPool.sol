// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedLiquidityPool - Private AMM liquidity pool with hidden reserve balances
contract EncryptedLiquidityPool is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    euint64 private reserveA;
    euint64 private reserveB;
    mapping(address => euint64) private lpShares;
    euint64 private totalShares;
    uint16 public feeBps = 30; // 0.3%

    event LiquidityAdded(address indexed provider);
    event LiquidityRemoved(address indexed provider);
    event Swapped(address indexed trader);

    constructor() Ownable(msg.sender) {
        reserveA = FHE.asEuint64(0);
        reserveB = FHE.asEuint64(0);
        totalShares = FHE.asEuint64(0);
        FHE.allowThis(reserveA);
        FHE.allowThis(reserveB);
        FHE.allowThis(totalShares);
    }

    function addLiquidity(
        externalEuint64 calldata encAmountA,
        externalEuint64 calldata encAmountB,
        bytes calldata proofA,
        bytes calldata proofB
    ) external nonReentrant {
        euint64 amtA = FHE.fromExternal(encAmountA, proofA);
        euint64 amtB = FHE.fromExternal(encAmountB, proofB);
        euint64 shares = FHE.add(amtA, amtB);
        reserveA = FHE.add(reserveA, amtA);
        reserveB = FHE.add(reserveB, amtB);
        lpShares[msg.sender] = FHE.add(lpShares[msg.sender], shares);
        totalShares = FHE.add(totalShares, shares);
        FHE.allowThis(reserveA);
        FHE.allowThis(reserveB);
        FHE.allowThis(lpShares[msg.sender]);
        FHE.allowThis(totalShares);
        FHE.allow(lpShares[msg.sender], msg.sender);
        emit LiquidityAdded(msg.sender);
    }

    function swapAforB(externalEuint64 calldata encAmountIn, bytes calldata inputProof) external nonReentrant {
        euint64 amtIn = FHE.fromExternal(encAmountIn, inputProof);
        euint64 fee = FHE.div(FHE.mul(amtIn, FHE.asEuint64(feeBps)), FHE.asEuint64(10000));
        euint64 amtInAfterFee = FHE.sub(amtIn, fee);
        euint64 amtOut = FHE.div(FHE.mul(amtInAfterFee, reserveB), FHE.add(reserveA, amtInAfterFee));
        reserveA = FHE.add(reserveA, amtIn);
        reserveB = FHE.sub(reserveB, amtOut);
        FHE.allowThis(reserveA);
        FHE.allowThis(reserveB);
        FHE.allowTransient(amtOut, msg.sender);
        emit Swapped(msg.sender);
    }

    function swapBforA(externalEuint64 calldata encAmountIn, bytes calldata inputProof) external nonReentrant {
        euint64 amtIn = FHE.fromExternal(encAmountIn, inputProof);
        euint64 fee = FHE.div(FHE.mul(amtIn, FHE.asEuint64(feeBps)), FHE.asEuint64(10000));
        euint64 amtInAfterFee = FHE.sub(amtIn, fee);
        euint64 amtOut = FHE.div(FHE.mul(amtInAfterFee, reserveA), FHE.add(reserveB, amtInAfterFee));
        reserveB = FHE.add(reserveB, amtIn);
        reserveA = FHE.sub(reserveA, amtOut);
        FHE.allowThis(reserveA);
        FHE.allowThis(reserveB);
        FHE.allowTransient(amtOut, msg.sender);
        emit Swapped(msg.sender);
    }

    function getLPShares(address provider) external view returns (euint64) {
        return lpShares[provider];
    }
}
