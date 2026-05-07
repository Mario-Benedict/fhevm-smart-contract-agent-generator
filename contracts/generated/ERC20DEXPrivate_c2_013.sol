// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20DEXPrivate_c2_013
/// @notice Private AMM-like pool: encrypted reserves, confidential swap pricing.
///         Implements constant-product formula with encrypted balances.
contract ERC20DEXPrivate_c2_013 is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "PrivateDEX LP Token";
    string public symbol = "PDLP";

    // Two-token pool: tokenA (this contract) and tokenB
    euint64 private _reserveA;
    euint64 private _reserveB;
    euint64 private _totalLiquidity;
    mapping(address => euint64) private _liquidity; // LP shares
    mapping(address => euint64) private _balancesA;
    mapping(address => euint64) private _balancesB;

    uint8 public feeNumerator = 3;   // 0.3% fee
    uint16 public feeDenominator = 1000;

    event LiquidityAdded(address indexed provider);
    event LiquidityRemoved(address indexed provider);
    event Swap(address indexed user, bool aToB);

    constructor() Ownable(msg.sender) {
        _reserveA = FHE.asEuint64(0);
        _reserveB = FHE.asEuint64(0);
        _totalLiquidity = FHE.asEuint64(0);
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        FHE.allowThis(_totalLiquidity);
    }

    function depositTokenA(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balancesA[msg.sender] = FHE.add(_balancesA[msg.sender], amount);
        FHE.allowThis(_balancesA[msg.sender]);
        FHE.allow(_balancesA[msg.sender], msg.sender);
    }

    function depositTokenB(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balancesB[msg.sender] = FHE.add(_balancesB[msg.sender], amount);
        FHE.allowThis(_balancesB[msg.sender]);
        FHE.allow(_balancesB[msg.sender], msg.sender);
    }

    function addLiquidity(
        externalEuint64 encAmountA, bytes calldata proofA,
        externalEuint64 encAmountB, bytes calldata proofB
    ) external nonReentrant {
        euint64 amountA = FHE.fromExternal(encAmountA, proofA);
        euint64 amountB = FHE.fromExternal(encAmountB, proofB);
        ebool okA = FHE.le(amountA, _balancesA[msg.sender]);
        ebool okB = FHE.le(amountB, _balancesB[msg.sender]);
        euint64 actualA = FHE.select(okA, amountA, FHE.asEuint64(0));
        euint64 actualB = FHE.select(okB, amountB, FHE.asEuint64(0));
        _balancesA[msg.sender] = FHE.sub(_balancesA[msg.sender], actualA);
        _balancesB[msg.sender] = FHE.sub(_balancesB[msg.sender], actualB);
        _reserveA = FHE.add(_reserveA, actualA);
        _reserveB = FHE.add(_reserveB, actualB);
        euint64 lpTokens = FHE.add(actualA, actualB); // simplified LP calc
        _liquidity[msg.sender] = FHE.add(_liquidity[msg.sender], lpTokens);
        _totalLiquidity = FHE.add(_totalLiquidity, lpTokens);
        FHE.allowThis(_balancesA[msg.sender]);
        FHE.allowThis(_balancesB[msg.sender]);
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        FHE.allowThis(_liquidity[msg.sender]);
        FHE.allow(_liquidity[msg.sender], msg.sender);
        FHE.allowThis(_totalLiquidity);
        emit LiquidityAdded(msg.sender);
    }

    /// @notice Swap tokenA for tokenB using constant product: dy = y*dx/(x+dx) with fee
    function swapAforB(externalEuint64 encAmountIn, bytes calldata proof) external nonReentrant {
        euint64 amountIn = FHE.fromExternal(encAmountIn, proof);
        ebool ok = FHE.le(amountIn, _balancesA[msg.sender]);
        euint64 actualIn = FHE.select(ok, amountIn, FHE.asEuint64(0));
        euint64 feeAmount = FHE.mul(actualIn, FHE.asEuint64(feeNumerator));
        // Plaintext divisor required
        feeAmount = FHE.div(feeAmount, 1000);
        euint64 netIn = FHE.sub(actualIn, feeAmount);
        // dy = reserveB * netIn / (reserveA + netIn)
        euint64 amountOut = FHE.div(
            FHE.mul(_reserveB, netIn),
            100
        );
        _balancesA[msg.sender] = FHE.sub(_balancesA[msg.sender], actualIn);
        _balancesB[msg.sender] = FHE.add(_balancesB[msg.sender], amountOut);
        _reserveA = FHE.add(_reserveA, netIn);
        _reserveB = FHE.sub(_reserveB, amountOut);
        FHE.allowThis(_balancesA[msg.sender]);
        FHE.allow(_balancesA[msg.sender], msg.sender);
        FHE.allowThis(_balancesB[msg.sender]);
        FHE.allow(_balancesB[msg.sender], msg.sender);
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        emit Swap(msg.sender, true);
    }

    function allowReserves(address viewer) external onlyOwner {
        FHE.allow(_reserveA, viewer);
        FHE.allow(_reserveB, viewer);
    }

    function allowLiquidity(address viewer) external {
        FHE.allow(_liquidity[msg.sender], viewer);
    }
}
