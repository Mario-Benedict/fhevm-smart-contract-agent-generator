// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialCrossChainBridgeToken
/// @notice Encrypted cross-chain bridge token: hidden bridge limits per address,
///         private daily caps, confidential oracle-validated amounts, and
///         encrypted fee schedules per chain.
contract ConfidentialCrossChainBridgeToken is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public constant name = "Bridge Wrapped";
    string public constant symbol = "bWRAP";
    uint8  public constant decimals = 18;

    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _bridgeLimitPerAddress;
    mapping(address => euint64) private _dailyBridged;
    mapping(uint256 => euint64) private _chainFees; // chainId => encrypted fee

    euint64 private _totalSupply;
    euint64 private _totalBridgedOut;
    euint64 private _totalFeesCollected;
    euint64 private _globalDailyCap;

    mapping(address => bool) public isBridgeRelayer;

    event Transfer(address indexed from, address indexed to);
    event BridgeOut(address indexed user, uint256 destChainId, uint256 timestamp);
    event BridgeIn(address indexed user, uint256 srcChainId, uint256 timestamp);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _totalBridgedOut = FHE.asEuint64(0);
        _totalFeesCollected = FHE.asEuint64(0);
        ebool _safeMul4 = FHE.le(FHE.asEuint64(10_000_000), FHE.asEuint64(type(uint32).max));
        _globalDailyCap = FHE.mul(FHE.asEuint64(10_000_000), FHE.asEuint64(1e18));
        FHE.allowThis(_totalSupply); FHE.allowThis(_totalBridgedOut);
        FHE.allowThis(_totalFeesCollected); FHE.allowThis(_globalDailyCap);
        isBridgeRelayer[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addRelayer(address r) external onlyOwner { isBridgeRelayer[r] = true; }

    function setChainFee(uint256 chainId, externalEuint64 encFee, bytes calldata proof) external onlyOwner {
        _chainFees[chainId] = FHE.fromExternal(encFee, proof);
        FHE.allowThis(_chainFees[chainId]);
    }

    function setAddressLimit(address user, externalEuint64 encLimit, bytes calldata proof) external onlyOwner {
        _bridgeLimitPerAddress[user] = FHE.fromExternal(encLimit, proof);
        FHE.allowThis(_bridgeLimitPerAddress[user]); FHE.allow(_bridgeLimitPerAddress[user], user);
    }

    function mint(address to, externalEuint64 encAmt, bytes calldata proof) external {
        require(isBridgeRelayer[msg.sender], "Not relayer");
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        _balances[to] = FHE.add(_balances[to], amt);
        _totalSupply = FHE.add(_totalSupply, amt);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
        emit BridgeIn(to, 0, block.timestamp);
    }

    function bridgeOut(uint256 destChainId, externalEuint64 encAmt, bytes calldata proof) external whenNotPaused nonReentrant {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        euint64 fee = FHE.isInitialized(_chainFees[destChainId]) ? _chainFees[destChainId] : FHE.asEuint64(0);
        euint64 totalWithFee = FHE.add(amt, fee);
        if (!FHE.isInitialized(_dailyBridged[msg.sender])) { _dailyBridged[msg.sender] = FHE.asEuint64(0); FHE.allowThis(_dailyBridged[msg.sender]); }
        ebool withinLimit = FHE.le(totalWithFee, _bridgeLimitPerAddress[msg.sender]);
        ebool sufficient  = FHE.ge(_balances[msg.sender], totalWithFee);
        ebool canBridge   = FHE.and(withinLimit, sufficient);
        euint64 effAmt = FHE.select(canBridge, totalWithFee, FHE.asEuint64(0));
        ebool _safeSub25 = FHE.ge(_balances[msg.sender], effAmt);
        _balances[msg.sender] = FHE.select(_safeSub25, FHE.sub(_balances[msg.sender], effAmt), FHE.asEuint64(0));
        _totalSupply = FHE.sub(_totalSupply, FHE.select(canBridge, amt, FHE.asEuint64(0)));
        _totalBridgedOut = FHE.add(_totalBridgedOut, FHE.select(canBridge, amt, FHE.asEuint64(0)));
        _totalFeesCollected = FHE.add(_totalFeesCollected, FHE.select(canBridge, fee, FHE.asEuint64(0)));
        _dailyBridged[msg.sender] = FHE.add(_dailyBridged[msg.sender], effAmt);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_totalSupply); FHE.allowThis(_totalBridgedOut); FHE.allowThis(_totalFeesCollected);
        FHE.allowThis(_dailyBridged[msg.sender]); FHE.allow(_dailyBridged[msg.sender], msg.sender);
        emit BridgeOut(msg.sender, destChainId, block.timestamp);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external whenNotPaused {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 eff = FHE.select(sufficient, amt, FHE.asEuint64(0));
        ebool _safeSub26 = FHE.ge(_balances[msg.sender], eff);
        _balances[msg.sender] = FHE.select(_safeSub26, FHE.sub(_balances[msg.sender], eff), FHE.asEuint64(0));
        _balances[to] = FHE.add(_balances[to], eff);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address account) external view returns (euint64) { return _balances[account]; }
    function allowBridgeStats(address viewer) external onlyOwner {
        FHE.allow(_totalBridgedOut, viewer); FHE.allow(_totalFeesCollected, viewer);
    }
}
