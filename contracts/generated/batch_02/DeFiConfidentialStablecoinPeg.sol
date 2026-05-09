// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiConfidentialStablecoinPeg
/// @notice Algorithmic stablecoin with encrypted collateral ratio management.
///         The protocol adjusts supply based on encrypted price deviation signals
///         while maintaining hidden reserves to prevent bank-run coordination attacks.
contract DeFiConfidentialStablecoinPeg is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "ConfStable";
    string public symbol = "CSTB";

    euint64 private _totalSupply;
    euint64 private _totalCollateral;
    euint64 private _targetRatioBps;      // encrypted target collateral ratio
    euint64 private _expansionRateBps;    // encrypted supply expansion rate
    euint64 private _contractionRateBps;  // encrypted supply contraction rate
    mapping(address => euint64) private _balances;

    event Minted(address indexed to);
    event Burned(address indexed from);
    event Rebase(bool expansion);

    constructor(
        externalEuint64 encTargetRatio, bytes memory rProof,
        externalEuint64 encExpansion, bytes memory eProof,
        externalEuint64 encContraction, bytes memory cProof
    ) Ownable(msg.sender) {
        _targetRatioBps = FHE.fromExternal(encTargetRatio, rProof);
        _expansionRateBps = FHE.fromExternal(encExpansion, eProof);
        _contractionRateBps = FHE.fromExternal(encContraction, cProof);
        _totalSupply = FHE.asEuint64(0);
        _totalCollateral = FHE.asEuint64(0);
        FHE.allowThis(_targetRatioBps);
        FHE.allowThis(_expansionRateBps);
        FHE.allowThis(_contractionRateBps);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_totalCollateral);
    }

    function depositAndMint(externalEuint64 encCollateral, bytes calldata proof, uint64 targetRatioPlaintext) external nonReentrant {
        euint64 collateral = FHE.fromExternal(encCollateral, proof);
        // Mint = collateral * 10000 / targetRatio
        euint64 toMint = targetRatioPlaintext > 0 ? FHE.div(FHE.mul(collateral, 10000), targetRatioPlaintext) : FHE.asEuint64(0);
        _balances[msg.sender] = FHE.add(_balances[msg.sender], toMint);
        _totalCollateral = FHE.add(_totalCollateral, collateral);
        _totalSupply = FHE.add(_totalSupply, toMint);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_totalCollateral);
        FHE.allowThis(_totalSupply);
        emit Minted(msg.sender);
    }

    function redeemAndBurn(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasBal = FHE.le(amount, _balances[msg.sender]);
        euint64 actual = FHE.select(hasBal, amount, FHE.asEuint64(0));
        euint64 collateralReturn = FHE.div(FHE.mul(actual, _targetRatioBps), 10000);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _totalSupply = FHE.sub(_totalSupply, actual);
        _totalCollateral = FHE.sub(_totalCollateral, collateralReturn);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(collateralReturn, msg.sender);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_totalCollateral);
        emit Burned(msg.sender);
    }

    function rebase(bool isExpansion, externalEuint64 encDeviation, bytes calldata proof) external onlyOwner {
        euint64 deviation = FHE.fromExternal(encDeviation, proof);
        if (isExpansion) {
            euint64 mintAmount = FHE.div(FHE.mul(_totalSupply, _expansionRateBps), 10000);
            _totalSupply = FHE.add(_totalSupply, mintAmount);
            _balances[owner()] = FHE.add(_balances[owner()], mintAmount);
            FHE.allowThis(_balances[owner()]);
            FHE.allow(_balances[owner()], owner());
        } else {
            euint64 burnAmount = FHE.div(FHE.mul(_totalSupply, _contractionRateBps), 10000);
            _totalSupply = FHE.sub(_totalSupply, burnAmount);
        }
        FHE.allowThis(_totalSupply);
        emit Rebase(isExpansion);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, _balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], actual);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function allowBalance(address viewer) external { FHE.allow(_balances[msg.sender], viewer); }
    function allowProtocolData(address viewer) external onlyOwner {
        FHE.allow(_totalSupply, viewer);
        FHE.allow(_totalCollateral, viewer);
    }
}
