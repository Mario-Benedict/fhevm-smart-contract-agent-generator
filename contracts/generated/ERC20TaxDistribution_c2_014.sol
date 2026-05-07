// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20TaxDistribution_c2_014
/// @notice Each transfer auto-taxes sender and distributes encrypted tax
///         to a pool. Token holders claim share of pool proportional to stake.
contract ERC20TaxDistribution_c2_014 is ZamaEthereumConfig, Ownable {
    string public name = "Auto-Tax Distribution Token";
    string public symbol = "ATD";

    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;
    euint64 private _taxPool;
    euint64 private _totalDistributed;
    mapping(address => euint64) private _taxDebt; // tracks claimed portion
    uint8 public taxBps; // basis points (e.g. 200 = 2%)

    event TaxCollected();
    event TaxClaimed(address indexed holder);

    constructor(uint8 _taxBps) Ownable(msg.sender) {
        taxBps = _taxBps;
        _totalSupply = FHE.asEuint64(0);
        _taxPool = FHE.asEuint64(0);
        _totalDistributed = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_taxPool);
        FHE.allowThis(_totalDistributed);
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, _balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        // Tax calculation: tax = actual * taxBps / 10000
        euint64 tax = FHE.div(FHE.mul(actual, FHE.asEuint64(uint64(taxBps))), 10000);
        euint64 net = FHE.sub(actual, tax);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], net);
        _taxPool = FHE.add(_taxPool, tax);
        _totalDistributed = FHE.add(_totalDistributed, tax);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_taxPool);
        FHE.allowThis(_totalDistributed);
        emit TaxCollected();
    }

    function claimTax() external {
        // Share = taxPool * balance / totalSupply
        euint64 share = FHE.div(FHE.mul(_taxPool, _balances[msg.sender]), 100);
        euint64 claimable = FHE.sub(share, _taxDebt[msg.sender]);
        _taxDebt[msg.sender] = FHE.add(_taxDebt[msg.sender], claimable);
        FHE.allowThis(_taxDebt[msg.sender]);
        FHE.allow(claimable, msg.sender);
        emit TaxClaimed(msg.sender);
    }

    function allowBalance(address viewer) external {
        FHE.allow(_balances[msg.sender], viewer);
    }

    function allowTaxPool(address viewer) external onlyOwner {
        FHE.allow(_taxPool, viewer);
    }
}
