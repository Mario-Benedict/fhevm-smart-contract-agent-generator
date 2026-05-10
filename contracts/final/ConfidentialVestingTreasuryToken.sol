// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialVestingTreasuryToken
/// @notice ERC20 with encrypted total supply, private treasury allocations, hidden
///         team vesting schedules, and encrypted ecosystem grant distribution tracking.
contract ConfidentialVestingTreasuryToken is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public constant name = "Vesting Treasury";
    string public constant symbol = "VSTT";
    uint8  public constant decimals = 18;

    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _vestLocked;
    mapping(address => uint256) public  vestEnd;
    euint64 private _totalSupply;
    euint64 private _treasuryAllocation;
    euint64 private _ecosystemGrants;

    event Minted(address indexed to);
    event Transfer(address indexed from, address indexed to);
    event VestingScheduled(address indexed beneficiary, uint256 vestEnd);
    event VestClaimed(address indexed beneficiary);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _treasuryAllocation = FHE.asEuint64(0);
        _ecosystemGrants = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_treasuryAllocation);
        FHE.allowThis(_ecosystemGrants);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function mint(address to, externalEuint64 encAmt, bytes calldata proof) external onlyOwner {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        _balances[to] = FHE.add(_balances[to], amt);
        _totalSupply = FHE.add(_totalSupply, amt);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
        emit Minted(to);
    }

    function allocateTreasury(externalEuint64 encAmt, bytes calldata proof) external onlyOwner {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        _treasuryAllocation = FHE.add(_treasuryAllocation, amt);
        _totalSupply = FHE.add(_totalSupply, amt);
        FHE.allowThis(_treasuryAllocation); FHE.allowThis(_totalSupply);
    }

    function grantEcosystemFunding(address recipient, externalEuint64 encGrant, bytes calldata proof) external onlyOwner {
        euint64 grant = FHE.fromExternal(encGrant, proof);
        if (!FHE.isInitialized(_balances[recipient])) { _balances[recipient] = FHE.asEuint64(0); FHE.allowThis(_balances[recipient]); }
        _balances[recipient] = FHE.add(_balances[recipient], grant);
        _ecosystemGrants = FHE.add(_ecosystemGrants, grant);
        FHE.allowThis(_balances[recipient]); FHE.allow(_balances[recipient], recipient);
        FHE.allowThis(_ecosystemGrants);
    }

    function scheduleVesting(address beneficiary, externalEuint64 encAmt, bytes calldata proof, uint256 durationDays) external onlyOwner {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_vestLocked[beneficiary])) { _vestLocked[beneficiary] = FHE.asEuint64(0); FHE.allowThis(_vestLocked[beneficiary]); }
        _vestLocked[beneficiary] = FHE.add(_vestLocked[beneficiary], amt);
        vestEnd[beneficiary] = block.timestamp + durationDays * 1 days;
        _totalSupply = FHE.add(_totalSupply, amt);
        FHE.allowThis(_vestLocked[beneficiary]); FHE.allow(_vestLocked[beneficiary], beneficiary);
        FHE.allowThis(_totalSupply);
        emit VestingScheduled(beneficiary, vestEnd[beneficiary]);
    }

    function claimVested() external whenNotPaused nonReentrant {
        require(block.timestamp >= vestEnd[msg.sender] && FHE.isInitialized(_vestLocked[msg.sender]), "Not vested");
        if (!FHE.isInitialized(_balances[msg.sender])) { _balances[msg.sender] = FHE.asEuint64(0); FHE.allowThis(_balances[msg.sender]); }
        _balances[msg.sender] = FHE.add(_balances[msg.sender], _vestLocked[msg.sender]);
        _vestLocked[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_vestLocked[msg.sender]); FHE.allow(_vestLocked[msg.sender], msg.sender);
        emit VestClaimed(msg.sender);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external whenNotPaused {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 eff = FHE.select(sufficient, amt, FHE.asEuint64(0));
        ebool _safeSub78 = FHE.ge(_balances[msg.sender], eff);
        _balances[msg.sender] = FHE.select(_safeSub78, FHE.sub(_balances[msg.sender], eff), FHE.asEuint64(0));
        _balances[to] = FHE.add(_balances[to], eff);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function allowTreasuryView(address viewer) external onlyOwner {
        FHE.allow(_treasuryAllocation, viewer); FHE.allow(_ecosystemGrants, viewer); FHE.allow(_totalSupply, viewer);
    }
}
