// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20AntiWhale_c2_008
/// @notice Token with encrypted max-holding limit per wallet.
///         Transfers that would exceed the limit are silently truncated.
contract ERC20AntiWhale_c2_008 is ZamaEthereumConfig, Ownable {
    string public name = "AntiWhale Token";
    string public symbol = "AWH";

    euint64 private _totalSupply;
    euint64 private _maxHolding; // encrypted max per wallet
    mapping(address => euint64) private _balances;
    mapping(address => bool) public isExempt; // whitelisted addresses

    event MaxHoldingUpdated();

    constructor(externalEuint64 encMax, bytes memory maxProof) Ownable(msg.sender) {
        _maxHolding = FHE.fromExternal(encMax, maxProof);
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_maxHolding);
        FHE.allowThis(_totalSupply);
        isExempt[msg.sender] = true;
    }

    function setMaxHolding(externalEuint64 encMax, bytes calldata proof) external onlyOwner {
        _maxHolding = FHE.fromExternal(encMax, proof);
        FHE.allowThis(_maxHolding);
        emit MaxHoldingUpdated();
    }

    function setExempt(address account, bool exempt) external onlyOwner {
        isExempt[account] = exempt;
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 wouldHave = FHE.add(_balances[to], amount);
        euint64 actual = isExempt[to]
            ? amount
            : FHE.select(FHE.le(wouldHave, _maxHolding), amount, FHE.sub(_maxHolding, _balances[to]));
        _balances[to] = FHE.add(_balances[to], actual);
        _totalSupply = FHE.add(_totalSupply, actual);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasFunds = FHE.le(amount, _balances[msg.sender]);
        euint64 preCheck = FHE.select(hasFunds, amount, FHE.asEuint64(0));
        // Anti-whale: cap by max holding (if not exempt)
        euint64 wouldHave = FHE.add(_balances[to], preCheck);
        euint64 actual = isExempt[to]
            ? preCheck
            : FHE.select(FHE.le(wouldHave, _maxHolding), preCheck, FHE.sub(_maxHolding, _balances[to]));
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

    function allowMaxHolding(address viewer) external onlyOwner {
        FHE.allow(_maxHolding, viewer);
    }
}
