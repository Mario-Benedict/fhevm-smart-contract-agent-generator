// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ERC20ConfidentialVault
/// @notice Reserve-backed confidential token with encrypted reserve ratio and peg maintenance.
contract ERC20ConfidentialVault is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public name = "ConfidentialVault USD";
    string public symbol = "cvUSD";
    uint8 public decimals = 18;

    euint64 private _totalSupply;
    euint64 private _totalReserve;
    euint64 private _minReserveRatioBps;
    euint64 private _redemptionFeeBps;

    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _reserveDeposited;

    event Minted(address indexed to);
    event Redeemed(address indexed from);

    constructor(
        externalEuint64 encMinRatio, bytes memory ratioProof,
        externalEuint64 encFee, bytes memory feeProof
    ) Ownable(msg.sender) {
        _minReserveRatioBps = FHE.fromExternal(encMinRatio, ratioProof);
        _redemptionFeeBps = FHE.fromExternal(encFee, feeProof);
        _totalSupply = FHE.asEuint64(0);
        _totalReserve = FHE.asEuint64(0);
        FHE.allowThis(_minReserveRatioBps);
        FHE.allowThis(_redemptionFeeBps);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_totalReserve);
    }

    function depositAndMint(externalEuint64 encCollateral, bytes calldata proof, uint64 minRatioPlaintext, uint64 newSupplyPlaintext) external nonReentrant whenNotPaused {
        euint64 collateral = FHE.fromExternal(encCollateral, proof);
        euint64 tokensToMint = minRatioPlaintext > 0 ? FHE.div(FHE.mul(collateral, 10000), minRatioPlaintext) : FHE.asEuint64(0);
        euint64 newReserve = FHE.add(_totalReserve, collateral);
        euint64 newSupply = FHE.add(_totalSupply, tokensToMint);
        euint64 newRatio = newSupplyPlaintext > 0 ? FHE.div(FHE.mul(newReserve, 10000), newSupplyPlaintext) : FHE.asEuint64(0);
        ebool healthy = FHE.ge(newRatio, _minReserveRatioBps);
        euint64 actualMint = FHE.select(healthy, tokensToMint, FHE.asEuint64(0));
        euint64 actualReserve = FHE.select(healthy, collateral, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.add(_balances[msg.sender], actualMint);
        _reserveDeposited[msg.sender] = FHE.add(_reserveDeposited[msg.sender], actualReserve);
        _totalSupply = FHE.add(_totalSupply, actualMint);
        _totalReserve = FHE.add(_totalReserve, actualReserve);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_reserveDeposited[msg.sender]);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_totalReserve);
        emit Minted(msg.sender);
    }

    function redeem(externalEuint64 encTokens, bytes calldata proof) external nonReentrant whenNotPaused {
        euint64 tokens = FHE.fromExternal(encTokens, proof);
        ebool hasTokens = FHE.le(tokens, _balances[msg.sender]);
        euint64 actual = FHE.select(hasTokens, tokens, FHE.asEuint64(0));
        euint64 collateralReturn = FHE.div(FHE.mul(actual, _minReserveRatioBps), 10000);
        euint64 fee = FHE.div(FHE.mul(collateralReturn, _redemptionFeeBps), 10000);
        euint64 netReturn = FHE.sub(collateralReturn, fee);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _totalSupply = FHE.sub(_totalSupply, actual);
        _totalReserve = FHE.sub(_totalReserve, netReturn);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(netReturn, msg.sender);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_totalReserve);
        emit Redeemed(msg.sender);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external whenNotPaused {
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

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function allowBalance(address viewer) external { FHE.allow(_balances[msg.sender], viewer); }
}
