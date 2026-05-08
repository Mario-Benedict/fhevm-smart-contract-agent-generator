// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialNexusGovernanceToken
/// @notice Encrypted governance ERC20 with private delegation, hidden voting weights,
///         and confidential snapshot-based governance power.
contract ConfidentialNexusGovernanceToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Nexus Governance";
    string public constant symbol = "NEXG";
    uint8  public constant decimals = 18;

    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _delegatedPower;
    mapping(address => address) public delegate;
    euint64 private _totalSupply;
    euint64 private _maxSupply;

    event Transfer(address indexed from, address indexed to);
    event Delegated(address indexed delegator, address indexed delegatee);
    event Minted(address indexed to);

    constructor(uint64 maxSupply) Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _maxSupply = FHE.asEuint64(maxSupply);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_maxSupply);
    }

    function mint(address to, externalEuint64 encAmt, bytes calldata proof) external onlyOwner {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        euint64 newSupply = FHE.add(_totalSupply, amt);
        ebool withinMax = FHE.le(newSupply, _maxSupply);
        euint64 effectiveAmt = FHE.select(withinMax, amt, FHE.asEuint64(0));
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        _balances[to] = FHE.add(_balances[to], effectiveAmt);
        _totalSupply = FHE.add(_totalSupply, effectiveAmt);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
        emit Minted(to);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external nonReentrant {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 effectiveAmt = FHE.select(sufficient, amt, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], effectiveAmt);
        _balances[to] = FHE.add(_balances[to], effectiveAmt);
        // Update delegation if active
        address del = delegate[msg.sender];
        if (del != address(0)) {
            if (!FHE.isInitialized(_delegatedPower[del])) { _delegatedPower[del] = FHE.asEuint64(0); FHE.allowThis(_delegatedPower[del]); }
            _delegatedPower[del] = FHE.sub(_delegatedPower[del], effectiveAmt);
            FHE.allowThis(_delegatedPower[del]); FHE.allow(_delegatedPower[del], del);
        }
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function delegateTo(address delegatee) external {
        address prev = delegate[msg.sender];
        if (prev != address(0) && FHE.isInitialized(_delegatedPower[prev])) {
            _delegatedPower[prev] = FHE.sub(_delegatedPower[prev], _balances[msg.sender]);
            FHE.allowThis(_delegatedPower[prev]); FHE.allow(_delegatedPower[prev], prev);
        }
        delegate[msg.sender] = delegatee;
        if (!FHE.isInitialized(_delegatedPower[delegatee])) { _delegatedPower[delegatee] = FHE.asEuint64(0); FHE.allowThis(_delegatedPower[delegatee]); }
        _delegatedPower[delegatee] = FHE.add(_delegatedPower[delegatee], _balances[msg.sender]);
        FHE.allowThis(_delegatedPower[delegatee]); FHE.allow(_delegatedPower[delegatee], delegatee);
        emit Delegated(msg.sender, delegatee);
    }

    function balanceOf(address account) external view returns (euint64) { return _balances[account]; }
    function votingPowerOf(address account) external view returns (euint64) { return _delegatedPower[account]; }
    function totalSupply() external view returns (euint64) { return _totalSupply; }
    function allowBalanceView(address account, address viewer) external onlyOwner { FHE.allow(_balances[account], viewer); }
    function allowVotingPowerView(address account, address viewer) external onlyOwner { FHE.allow(_delegatedPower[account], viewer); }
}
