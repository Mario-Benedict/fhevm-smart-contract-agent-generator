// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialFeeOnTransferToken
/// @notice ERC20 with encrypted fee-on-transfer, private burn rate, hidden reflections
///         distribution to holders, and confidential liquidity allocation tracking.
contract ConfidentialFeeOnTransferToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Fee Reflection";
    string public constant symbol = "FRFL";
    uint8  public constant decimals = 9;

    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _reflections;
    euint64 private _totalSupply;
    euint64 private _totalReflectionPool;
    euint64 private _totalBurned;
    euint64 private _transferFeeBps;   // encrypted fee rate
    euint64 private _burnRateBps;      // encrypted burn rate
    euint64 private _reflectRateBps;   // encrypted reflection rate

    event Transfer(address indexed from, address indexed to);
    event Burned(address indexed from, uint256 timestamp);
    event ReflectionAdded(uint256 timestamp);

    constructor(uint64 supply) Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(uint64(supply));
        _totalReflectionPool = FHE.asEuint64(0);
        _totalBurned = FHE.asEuint64(0);
        _transferFeeBps = FHE.asEuint64(300);   // 3%
        _burnRateBps = FHE.asEuint64(100);       // 1%
        _reflectRateBps = FHE.asEuint64(200);    // 2%
        _balances[msg.sender] = FHE.asEuint64(uint64(supply));
        FHE.allowThis(_totalSupply); FHE.allowThis(_totalReflectionPool);
        FHE.allowThis(_totalBurned); FHE.allowThis(_transferFeeBps);
        FHE.allowThis(_burnRateBps); FHE.allowThis(_reflectRateBps);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
    }

    function updateFees(externalEuint64 encFee, bytes calldata fProof, externalEuint64 encBurn, bytes calldata bProof, externalEuint64 encReflect, bytes calldata rProof) external onlyOwner {
        _transferFeeBps = FHE.fromExternal(encFee, fProof);
        _burnRateBps = FHE.fromExternal(encBurn, bProof);
        _reflectRateBps = FHE.fromExternal(encReflect, rProof);
        FHE.allowThis(_transferFeeBps); FHE.allowThis(_burnRateBps); FHE.allowThis(_reflectRateBps);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external nonReentrant {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        if (!FHE.isInitialized(_reflections[to])) { _reflections[to] = FHE.asEuint64(0); FHE.allowThis(_reflections[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 eff = FHE.select(sufficient, amt, FHE.asEuint64(0));
        // Split: burnAmt, reflectAmt, net
        euint64 burnAmt    = FHE.div(FHE.mul(eff, _burnRateBps), 10000);
        euint64 reflectAmt = FHE.div(FHE.mul(eff, _reflectRateBps), 10000);
        euint64 feeAmt     = FHE.div(FHE.mul(eff, _transferFeeBps), 10000);
        euint64 netAmt     = FHE.sub(FHE.sub(FHE.sub(eff, burnAmt), reflectAmt), feeAmt);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], eff);
        _balances[to] = FHE.add(_balances[to], netAmt);
        _totalBurned = FHE.add(_totalBurned, burnAmt);
        _totalSupply = FHE.sub(_totalSupply, burnAmt);
        _totalReflectionPool = FHE.add(_totalReflectionPool, reflectAmt);
        _reflections[to] = FHE.add(_reflections[to], reflectAmt);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        FHE.allowThis(_totalBurned); FHE.allowThis(_totalSupply); FHE.allowThis(_totalReflectionPool);
        FHE.allowThis(_reflections[to]); FHE.allow(_reflections[to], to);
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address account) external view returns (euint64) { return _balances[account]; }
    function reflectionsOf(address account) external view returns (euint64) { return _reflections[account]; }
    function allowStats(address viewer) external onlyOwner {
        FHE.allow(_totalSupply, viewer); FHE.allow(_totalBurned, viewer); FHE.allow(_totalReflectionPool, viewer);
    }
}
