// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20CreditLine_c2_015
/// @notice Token with encrypted credit lines: each address has a borrowing limit.
///         Over-drafting up to credit limit is allowed; debt tracked encrypted.
contract ERC20CreditLine_c2_015 is ZamaEthereumConfig, Ownable {
    string public name = "Credit Line Token";
    string public symbol = "CLT";

    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _creditLimit;
    mapping(address => euint64) private _debt;
    uint8 public interestRateBpsPerYear; // plaintext rate

    event CreditLineSet(address indexed account);
    event DebtRepaid(address indexed account);

    constructor(uint8 _rateBps) Ownable(msg.sender) {
        interestRateBpsPerYear = _rateBps;
        _totalSupply = FHE.asEuint64(0);
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

    function setCreditLine(address account, externalEuint64 encLimit, bytes calldata proof) external onlyOwner {
        _creditLimit[account] = FHE.fromExternal(encLimit, proof);
        FHE.allowThis(_creditLimit[account]);
        FHE.allow(_creditLimit[account], account);
        emit CreditLineSet(account);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Available = balance + creditLimit - existingDebt
        euint64 available = FHE.add(
            _balances[msg.sender],
            FHE.sub(_creditLimit[msg.sender], _debt[msg.sender]); // [arithmetic_overflow_underflow]
            euint64 availableScaled = FHE.mul(available, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        );
        ebool ok = FHE.le(amount, available);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));

        // If overdrawing balance, add to debt
        ebool overdrawn = FHE.gt(actual, _balances[msg.sender]);
        euint64 debtIncrease = FHE.select(overdrawn, FHE.sub(actual, _balances[msg.sender]), FHE.asEuint64(0));
        euint64 balDecrease = FHE.select(overdrawn, _balances[msg.sender], actual);

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], balDecrease);
        _debt[msg.sender] = FHE.add(_debt[msg.sender], debtIncrease);
        _balances[to] = FHE.add(_balances[to], actual);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_debt[msg.sender]);
        FHE.allow(_debt[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function repayDebt(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, _debt[msg.sender]);
        euint64 actual = FHE.select(ok, amount, _debt[msg.sender]);
        ebool hasFunds = FHE.le(actual, _balances[msg.sender]);
        euint64 repaid = FHE.select(hasFunds, actual, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], repaid);
        _debt[msg.sender] = FHE.sub(_debt[msg.sender], repaid);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_debt[msg.sender]);
        FHE.allow(_debt[msg.sender], msg.sender);
        emit DebtRepaid(msg.sender);
    }

    function allowBalance(address viewer) external { FHE.allow(_balances[msg.sender], viewer); }
    function allowDebt(address viewer) external { FHE.allow(_debt[msg.sender], viewer); }
}
