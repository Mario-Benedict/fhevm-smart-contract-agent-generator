// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20ConditionalTransfer_c2_010
/// @notice Transfers only execute if encrypted on-chain conditions are met
///         (e.g. sender balance above minimum, recipient not in blacklist).
contract ERC20ConditionalTransfer_c2_010 is ZamaEthereumConfig, Ownable {
    string public name = "Conditional Token";
    string public symbol = "CTK";

    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;
    mapping(address => ebool) private _blocked;
    euint64 private _minBalanceAfterTransfer; // sender must keep this much

    event Blocked(address indexed account);
    event Unblocked(address indexed account);

    constructor(externalEuint64 encMinBal, bytes memory proof) Ownable(msg.sender) {
        _minBalanceAfterTransfer = FHE.fromExternal(encMinBal, proof);
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_minBalanceAfterTransfer);
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

    function block_(address account) external onlyOwner {
        _blocked[account] = FHE.asEbool(true);
        FHE.allowThis(_blocked[account]);
        emit Blocked(account);
    }

    function unblock(address account) external onlyOwner {
        _blocked[account] = FHE.asEbool(false);
        FHE.allowThis(_blocked[account]);
        emit Unblocked(account);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Condition 1: sender not blocked
        ebool senderOk = FHE.not(_blocked[msg.sender]);
        // Condition 2: recipient not blocked
        ebool recipientOk = FHE.not(_blocked[to]);
        // Condition 3: sender keeps minimum balance
        euint64 remaining = FHE.sub(_balances[msg.sender], amount);
        ebool minBalOk = FHE.ge(remaining, _minBalanceAfterTransfer);
        // Condition 4: sufficient balance
        ebool hasFunds = FHE.le(amount, _balances[msg.sender]);

        ebool canTransfer = FHE.and(FHE.and(senderOk, recipientOk), FHE.and(minBalOk, hasFunds));
        euint64 actual = FHE.select(canTransfer, amount, FHE.asEuint64(0));

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], actual);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function allowBalance(address viewer) external {
        FHE.allow(_balances[msg.sender], viewer);
    }
}
