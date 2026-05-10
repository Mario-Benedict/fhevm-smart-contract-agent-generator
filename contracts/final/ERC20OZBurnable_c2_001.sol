// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ERC20OZBurnable_c2_001
/// @notice Confidential ERC20 with OZ Ownable + Pausable, burn mechanism,
///         and encrypted per-user burn-limit enforced on-chain.
contract ERC20OZBurnable_c2_001 is ZamaEthereumConfig, Ownable, Pausable {
    string public name = "ConfiBurn Token";
    string public symbol = "CBT";
    uint8 public decimals = 18;

    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _burnQuota; // max tokens burnable per address
    mapping(address => euint64) private _burnedSoFar;

    event Mint(address indexed to);
    event Burn(address indexed from);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof) external onlyOwner whenNotPaused {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
        emit Mint(to);
    }

    function setBurnQuota(address user, externalEuint64 encQuota, bytes calldata proof) external onlyOwner {
        _burnQuota[user] = FHE.fromExternal(encQuota, proof);
        FHE.allowThis(_burnQuota[user]);
        FHE.allow(_burnQuota[user], user);
    }

    function burn(externalEuint64 encAmount, bytes calldata proof) external whenNotPaused {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Enforce burn quota: burned + amount <= quota
        euint64 newBurned = FHE.add(_burnedSoFar[msg.sender], amount);
        ebool withinQuota = FHE.le(newBurned, _burnQuota[msg.sender]);
        euint64 actualBurn = FHE.select(withinQuota, amount, FHE.asEuint64(0));
        ebool hasFunds = FHE.le(actualBurn, _balances[msg.sender]);
        actualBurn = FHE.select(hasFunds, actualBurn, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actualBurn); // [arithmetic_overflow_underflow]
        euint64 actualBurnScaled = FHE.mul(actualBurn, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        _burnedSoFar[msg.sender] = FHE.add(_burnedSoFar[msg.sender], actualBurn);
        _totalSupply = FHE.sub(_totalSupply, actualBurn);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_burnedSoFar[msg.sender]);
        FHE.allowThis(_totalSupply);
        emit Burn(msg.sender);
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

    function allowBalance(address viewer) external {
        FHE.allow(_balances[msg.sender], viewer);
    }

    function allowTotalSupply(address viewer) external onlyOwner {
        FHE.allow(_totalSupply, viewer);
    }
}
