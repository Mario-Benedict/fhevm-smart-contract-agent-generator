// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20PrivateRemittance
/// @notice Cross-border remittance token with encrypted FX rates, transfer fees, and daily limits.
///         Senders encrypt their remittance amount; the contract applies hidden FX conversion
///         and deducts a confidential fee before crediting the recipient in the target currency.
contract ERC20PrivateRemittance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "RemitConfidential";
    string public symbol = "REMC";
    uint8 public decimals = 6;

    // Encrypted FX rate: how many target-currency units per 1 source-currency unit (scaled x1e6)
    euint64 private _fxRateBps;
    // Encrypted fee in basis points (e.g., 50 = 0.5%)
    euint64 private _feeBps;
    // Encrypted daily transfer limit per sender
    euint64 private _dailyLimitPerSender;

    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _dailySent;
    mapping(address => uint256) private _lastSentDay;

    event RemittanceSent(address indexed from, address indexed to);
    event FXRateUpdated();

    constructor(
        externalEuint64 encFxRate, bytes memory fxProof,
        externalEuint64 encFee, bytes memory feeProof,
        externalEuint64 encDailyLimit, bytes memory dlProof
    ) Ownable(msg.sender) {
        _fxRateBps = FHE.fromExternal(encFxRate, fxProof);
        _feeBps = FHE.fromExternal(encFee, feeProof);
        _dailyLimitPerSender = FHE.fromExternal(encDailyLimit, dlProof);
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_fxRateBps);
        FHE.allowThis(_feeBps);
        FHE.allowThis(_dailyLimitPerSender);
        FHE.allowThis(_totalSupply);
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
    }

    function remit(address to, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);

        // Reset daily counter if new day
        if (block.timestamp / 1 days > _lastSentDay[msg.sender]) {
            _dailySent[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_dailySent[msg.sender]);
            _lastSentDay[msg.sender] = block.timestamp / 1 days;
        }

        // Enforce daily limit
        euint64 newDailySent = FHE.add(_dailySent[msg.sender], amount);
        ebool withinLimit = FHE.le(newDailySent, _dailyLimitPerSender);
        euint64 actualAmount = FHE.select(withinLimit, amount, FHE.asEuint64(0));

        // Deduct fee
        euint64 feeAmount = FHE.div(FHE.mul(actualAmount, _feeBps), 10000); // [arithmetic_overflow_underflow]
        euint64 actualAmountScaled = FHE.mul(actualAmount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 netAmount = FHE.sub(actualAmount, feeAmount);

        // Apply FX conversion
        euint64 converted = FHE.div(FHE.mul(netAmount, _fxRateBps), 1000000);

        // Enforce balance
        ebool hasFunds = FHE.le(actualAmount, _balances[msg.sender]);
        euint64 finalDeduct = FHE.select(hasFunds, actualAmount, FHE.asEuint64(0));
        euint64 finalCredit = FHE.select(hasFunds, converted, FHE.asEuint64(0));

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], finalDeduct);
        _balances[to] = FHE.add(_balances[to], finalCredit);
        _dailySent[msg.sender] = FHE.add(_dailySent[msg.sender], finalDeduct);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_dailySent[msg.sender]);

        emit RemittanceSent(msg.sender, to);
    }

    function updateFXRate(externalEuint64 encRate, bytes calldata proof) external onlyOwner {
        _fxRateBps = FHE.fromExternal(encRate, proof);
        FHE.allowThis(_fxRateBps);
        emit FXRateUpdated();
    }

    function allowBalance(address viewer) external {
        FHE.allow(_balances[msg.sender], viewer);
    }
}
