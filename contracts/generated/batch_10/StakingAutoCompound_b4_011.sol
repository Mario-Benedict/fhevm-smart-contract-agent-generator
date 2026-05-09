// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title StakingAutoCompound_b4_011 - Auto-compounding staking with encrypted positions
contract StakingAutoCompound_b4_011 is ZamaEthereumConfig {
    address public owner;
    euint64 private totalShares;
    euint64 private totalUnderlying;
    mapping(address => euint64) private userShares;
    uint64 public compoundIntervalSeconds;
    uint256 public lastCompound;
    uint8 public aprPercent;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint8 _apr, uint64 _compoundInterval) {
        owner = msg.sender;
        aprPercent = _apr;
        compoundIntervalSeconds = _compoundInterval;
        lastCompound = block.timestamp;
        totalShares = FHE.asEuint64(0);
        totalUnderlying = FHE.asEuint64(0);
        FHE.allowThis(totalShares);
        FHE.allowThis(totalUnderlying);
    }

    function compound() public {
        require(block.timestamp >= lastCompound + compoundIntervalSeconds, "Too soon");
        uint256 elapsed = block.timestamp - lastCompound;
        uint64 interest = uint64((elapsed * aprPercent) / (365 days * 100));
        euint64 accrued = FHE.mul(totalUnderlying, FHE.asEuint64(uint64(interest)));
        totalUnderlying = FHE.add(totalUnderlying, accrued);
        lastCompound = block.timestamp;
        FHE.allowThis(totalUnderlying);
    }

    function deposit(externalEuint64 amountStr, bytes calldata proof) public {
        compound();
        euint64 amount = FHE.fromExternal(amountStr, proof);
        // shares = amount * totalShares / totalUnderlying (simplified: 1:1 if empty)
        euint64 newShares = amount; // simplified 1:1 ratio
        userShares[msg.sender] = FHE.add(userShares[msg.sender], newShares);
        totalShares = FHE.add(totalShares, newShares);
        totalUnderlying = FHE.add(totalUnderlying, amount);
        FHE.allowThis(userShares[msg.sender]);
        FHE.allowThis(totalShares);
        FHE.allowThis(totalUnderlying);
    }

    function withdraw(externalEuint64 sharesStr, bytes calldata proof) public {
        compound();
        euint64 shares = FHE.fromExternal(sharesStr, proof);
        ebool ok = FHE.le(shares, userShares[msg.sender]);
        euint64 actual = FHE.select(ok, shares, userShares[msg.sender]);
        // underlying = shares (1:1 simplified)
        userShares[msg.sender] = FHE.sub(userShares[msg.sender], actual);
        totalShares = FHE.sub(totalShares, actual);
        totalUnderlying = FHE.sub(totalUnderlying, actual);
        FHE.allowThis(userShares[msg.sender]);
        FHE.allowThis(totalShares);
        FHE.allowThis(totalUnderlying);
        FHE.allow(actual, msg.sender);
    }

    function allowShares(address viewer) public {
        FHE.allow(userShares[msg.sender], viewer);
    }
}
