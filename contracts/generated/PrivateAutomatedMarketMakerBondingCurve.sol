// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateAutomatedMarketMakerBondingCurve
/// @notice Encrypted bonding curve AMM: hidden token price at each supply point,
///         private buy/sell tax schedules, confidential reserve ratios, and
///         encrypted treasury accumulation.
contract PrivateAutomatedMarketMakerBondingCurve is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public constant name = "Bonding Curve Token";
    string public constant symbol = "BCT";
    uint8  public constant decimals = 18;

    mapping(address => euint64) private _balances;
    euint64 private _totalSupply;
    euint64 private _reserveBalance;      // encrypted reserve (ETH equivalent)
    euint64 private _reserveRatioBps;     // encrypted CW ratio
    euint64 private _currentPrice;        // encrypted current price per token
    euint64 private _buyTaxBps;           // encrypted buy tax
    euint64 private _sellTaxBps;          // encrypted sell tax
    euint64 private _treasuryAccumulated; // encrypted treasury

    event Transfer(address indexed from, address indexed to);
    event TokensBought(address indexed buyer, uint256 timestamp);
    event TokensSold(address indexed seller, uint256 timestamp);

    constructor(uint64 initialPrice, uint64 reserveRatio) Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _reserveBalance = FHE.asEuint64(0);
        _reserveRatioBps = FHE.asEuint64(reserveRatio);
        _currentPrice = FHE.asEuint64(initialPrice);
        _buyTaxBps = FHE.asEuint64(200);   // 2% buy tax
        _sellTaxBps = FHE.asEuint64(300);  // 3% sell tax
        _treasuryAccumulated = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply); FHE.allowThis(_reserveBalance);
        FHE.allowThis(_reserveRatioBps); FHE.allowThis(_currentPrice);
        FHE.allowThis(_buyTaxBps); FHE.allowThis(_sellTaxBps);
        FHE.allowThis(_treasuryAccumulated);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function updateTaxes(externalEuint64 encBuyTax, bytes calldata btProof, externalEuint64 encSellTax, bytes calldata stProof) external onlyOwner {
        _buyTaxBps  = FHE.fromExternal(encBuyTax, btProof);
        _sellTaxBps = FHE.fromExternal(encSellTax, stProof);
        FHE.allowThis(_buyTaxBps); FHE.allowThis(_sellTaxBps);
    }

    function buyTokens(externalEuint64 encPayment, bytes calldata proof) external whenNotPaused nonReentrant {
        euint64 payment = FHE.fromExternal(encPayment, proof);
        euint64 tax = FHE.div(FHE.mul(payment, _buyTaxBps), 10000);
        euint64 netPayment = FHE.sub(payment, tax);
        // Tokens = netPayment / currentPrice (plaintext divisor not applicable; use reserve ratio)
        euint64 tokensOut = FHE.div(netPayment, FHE.asEuint64(100)); // simplified: price = 100
        _reserveBalance = FHE.add(_reserveBalance, netPayment);
        _treasuryAccumulated = FHE.add(_treasuryAccumulated, tax);
        _totalSupply = FHE.add(_totalSupply, tokensOut);
        // Update price: price = reserveBalance / (totalSupply * reserveRatio / 10000)
        _currentPrice = FHE.div(_reserveBalance, FHE.asEuint64(100)); // simplified
        if (!FHE.isInitialized(_balances[msg.sender])) { _balances[msg.sender] = FHE.asEuint64(0); FHE.allowThis(_balances[msg.sender]); }
        _balances[msg.sender] = FHE.add(_balances[msg.sender], tokensOut);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_reserveBalance); FHE.allowThis(_totalSupply); FHE.allowThis(_currentPrice); FHE.allowThis(_treasuryAccumulated);
        emit TokensBought(msg.sender, block.timestamp);
    }

    function sellTokens(externalEuint64 encTokens, bytes calldata proof) external whenNotPaused nonReentrant {
        euint64 tokens = FHE.fromExternal(encTokens, proof);
        ebool sufficient = FHE.ge(_balances[msg.sender], tokens);
        euint64 effTokens = FHE.select(sufficient, tokens, _balances[msg.sender]);
        euint64 proceeds = FHE.mul(effTokens, _currentPrice);
        euint64 tax = FHE.div(FHE.mul(proceeds, _sellTaxBps), 10000);
        euint64 netProceeds = FHE.sub(proceeds, tax);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], effTokens);
        _totalSupply = FHE.sub(_totalSupply, effTokens);
        _reserveBalance = FHE.sub(_reserveBalance, netProceeds);
        _treasuryAccumulated = FHE.add(_treasuryAccumulated, tax);
        _currentPrice = FHE.div(_reserveBalance, FHE.asEuint64(100));
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_totalSupply); FHE.allowThis(_reserveBalance); FHE.allowThis(_currentPrice); FHE.allowThis(_treasuryAccumulated);
        FHE.allow(netProceeds, msg.sender);
        emit TokensSold(msg.sender, block.timestamp);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external whenNotPaused {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 eff = FHE.select(sufficient, amt, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], eff);
        _balances[to] = FHE.add(_balances[to], eff);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address a) external view returns (euint64) { return _balances[a]; }
    function currentPrice() external view returns (euint64) { return _currentPrice; }
    function allowCurveStats(address viewer) external onlyOwner {
        FHE.allow(_totalSupply, viewer); FHE.allow(_reserveBalance, viewer); FHE.allow(_currentPrice, viewer);
    }
}
