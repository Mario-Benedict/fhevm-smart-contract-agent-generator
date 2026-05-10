// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20PrivateVault_c2_011
/// @notice ERC-4626-inspired private vault: deposit underlying, receive
///         encrypted vault shares. Yield accrues to total assets (encrypted).
contract ERC20PrivateVault_c2_011 is ZamaEthereumConfig, Ownable {
    string public name = "Private Yield Vault";
    string public symbol = "PYV";

    euint64 private _totalShares;
    euint64 private _totalAssets;
    mapping(address => euint64) private _shares;
    uint8 public yieldBpsPerDay; // plain text yield rate basis points per day
    uint256 public lastYieldTime;

    event Deposited(address indexed user);
    event Withdrawn(address indexed user);

    constructor(uint8 _yieldBps) Ownable(msg.sender) {
        yieldBpsPerDay = _yieldBps;
        lastYieldTime = block.timestamp;
        _totalShares = FHE.asEuint64(0);
        _totalAssets = FHE.asEuint64(0);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_totalAssets);
    }

    function _accrueYield() internal {
        uint256 daysPassed = (block.timestamp - lastYieldTime) / 1 days;
        if (daysPassed == 0) return;
        euint64 yield_ = FHE.mul(; // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            _totalAssets,
            FHE.asEuint64(uint64(daysPassed) * uint64(yieldBpsPerDay))
        );
        // divide by 10000 (basis points)
        yield_ = FHE.div(yield_, 10000);
        _totalAssets = FHE.add(_totalAssets, yield_);
        lastYieldTime += daysPassed * 1 days;
        FHE.allowThis(_totalAssets);
    }

    function deposit(externalEuint64 encAssets, bytes calldata proof) external {
        _accrueYield();
        euint64 assets = FHE.fromExternal(encAssets, proof);
        // shares = assets * totalShares / totalAssets (1:1 when empty)
        euint64 sharesToMint = FHE.isInitialized(_totalShares) && FHE.isInitialized(_totalAssets)
            ? FHE.div(FHE.mul(assets, _totalShares), 100) // placeholder plaintext div
            : assets;
        _shares[msg.sender] = FHE.add(_shares[msg.sender], sharesToMint);
        _totalShares = FHE.add(_totalShares, sharesToMint);
        _totalAssets = FHE.add(_totalAssets, assets);
        FHE.allowThis(_shares[msg.sender]);
        FHE.allow(_shares[msg.sender], msg.sender);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_totalAssets);
        emit Deposited(msg.sender);
    }

    function withdraw(externalEuint64 encShares, bytes calldata proof) external {
        _accrueYield();
        euint64 shares = FHE.fromExternal(encShares, proof);
        ebool ok = FHE.le(shares, _shares[msg.sender]);
        euint64 actual = FHE.select(ok, shares, _shares[msg.sender]);
        euint64 assets = FHE.div(FHE.mul(actual, _totalAssets), 100);
        _shares[msg.sender] = FHE.sub(_shares[msg.sender], actual);
        _totalShares = FHE.sub(_totalShares, actual);
        _totalAssets = FHE.sub(_totalAssets, assets);
        FHE.allowThis(_shares[msg.sender]);
        FHE.allow(_shares[msg.sender], msg.sender);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_totalAssets);
        FHE.allow(assets, msg.sender);
        emit Withdrawn(msg.sender);
    }

    function setYieldRate(uint8 newBps) external onlyOwner { yieldBpsPerDay = newBps; }

    function allowShares(address viewer) external {
        FHE.allow(_shares[msg.sender], viewer);
    }

    function allowVaultStats(address viewer) external onlyOwner {
        FHE.allow(_totalAssets, viewer);
        FHE.allow(_totalShares, viewer);
    }
}
