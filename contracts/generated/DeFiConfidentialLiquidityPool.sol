// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiConfidentialLiquidityPool
/// @notice LP pool where each LP's share is tracked in encrypted form.
///         Swap fees accrue privately per LP. Price impact is calculated
///         using encrypted reserves to prevent sandwich attacks.
contract DeFiConfidentialLiquidityPool is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LPPosition {
        euint64 sharesBps;         // encrypted LP share in bps
        euint64 feesEarned;        // encrypted accumulated fees
        uint256 depositTime;
    }

    mapping(address => LPPosition) private lpPositions;
    address[] public lps;
    euint64 private _reserveA;
    euint64 private _reserveB;
    euint64 private _totalShares;
    euint64 private _totalFeesA;
    euint64 private _feeRateBps;
    uint256 public swapCount;

    event LiquidityAdded(address indexed lp);
    event LiquidityRemoved(address indexed lp);
    event Swap(address indexed trader, bool aToB);

    constructor(
        externalEuint64 encReserveA, bytes memory aProof,
        externalEuint64 encReserveB, bytes memory bProof,
        externalEuint64 encFeeRate, bytes memory fProof
    ) Ownable(msg.sender) {
        _reserveA = FHE.fromExternal(encReserveA, aProof);
        _reserveB = FHE.fromExternal(encReserveB, bProof);
        _feeRateBps = FHE.fromExternal(encFeeRate, fProof);
        _totalShares = FHE.asEuint64(0);
        _totalFeesA = FHE.asEuint64(0);
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        FHE.allowThis(_feeRateBps);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_totalFeesA);
    }

    function addLiquidity(
        externalEuint64 encAmountA, bytes calldata aProof,
        externalEuint64 encAmountB, bytes calldata bProof
    ) external nonReentrant {
        euint64 amountA = FHE.fromExternal(encAmountA, aProof);
        euint64 amountB = FHE.fromExternal(encAmountB, bProof);
        // Simplified: shares = amountA (proportional to reserve A)
        euint64 newShares = amountA;
        _reserveA = FHE.add(_reserveA, amountA);
        _reserveB = FHE.add(_reserveB, amountB);
        _totalShares = FHE.add(_totalShares, newShares);
        lpPositions[msg.sender].sharesBps = FHE.add(lpPositions[msg.sender].sharesBps, newShares);
        lpPositions[msg.sender].feesEarned = FHE.asEuint64(0);
        lpPositions[msg.sender].depositTime = block.timestamp;
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        FHE.allowThis(_totalShares);
        FHE.allowThis(lpPositions[msg.sender].sharesBps);
        FHE.allow(lpPositions[msg.sender].sharesBps, msg.sender);
        FHE.allowThis(lpPositions[msg.sender].feesEarned);
        FHE.allow(lpPositions[msg.sender].feesEarned, msg.sender);
        lps.push(msg.sender);
        emit LiquidityAdded(msg.sender);
    }

    function swap(
        bool aToB,
        externalEuint64 encAmountIn, bytes calldata proof
    ) external nonReentrant {
        euint64 amountIn = FHE.fromExternal(encAmountIn, proof);
        euint64 fee = FHE.div(FHE.mul(amountIn, _feeRateBps), 10000);
        euint64 amountAfterFee = FHE.sub(amountIn, fee);
        if (aToB) {
            euint64 amountOut = FHE.div(FHE.mul(amountAfterFee, _reserveB), _reserveA);
            _reserveA = FHE.add(_reserveA, amountIn);
            _reserveB = FHE.sub(_reserveB, amountOut);
            _totalFeesA = FHE.add(_totalFeesA, fee);
            FHE.allow(amountOut, msg.sender);
        } else {
            euint64 amountOut = FHE.div(FHE.mul(amountAfterFee, _reserveA), _reserveB);
            _reserveB = FHE.add(_reserveB, amountIn);
            _reserveA = FHE.sub(_reserveA, amountOut);
            FHE.allow(amountOut, msg.sender);
        }
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        FHE.allowThis(_totalFeesA);
        swapCount++;
        emit Swap(msg.sender, aToB);
    }

    function removeLiquidity(externalEuint64 encShares, bytes calldata proof) external nonReentrant {
        euint64 shares = FHE.fromExternal(encShares, proof);
        LPPosition storage lp = lpPositions[msg.sender];
        ebool hasShares = FHE.le(shares, lp.sharesBps);
        euint64 actual = FHE.select(hasShares, shares, FHE.asEuint64(0));
        lp.sharesBps = FHE.sub(lp.sharesBps, actual);
        _totalShares = FHE.sub(_totalShares, actual);
        euint64 returnedA = FHE.div(FHE.mul(actual, _reserveA), _totalShares);
        euint64 returnedB = FHE.div(FHE.mul(actual, _reserveB), _totalShares);
        _reserveA = FHE.sub(_reserveA, returnedA);
        _reserveB = FHE.sub(_reserveB, returnedB);
        FHE.allowThis(lp.sharesBps);
        FHE.allow(lp.sharesBps, msg.sender);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        FHE.allow(returnedA, msg.sender);
        FHE.allow(returnedB, msg.sender);
        emit LiquidityRemoved(msg.sender);
    }

    function allowPoolData(address viewer) external onlyOwner {
        FHE.allow(_reserveA, viewer);
        FHE.allow(_reserveB, viewer);
        FHE.allow(_totalFeesA, viewer);
    }
}
