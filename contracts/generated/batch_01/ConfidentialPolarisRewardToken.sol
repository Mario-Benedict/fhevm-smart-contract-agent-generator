// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialPolarisRewardToken
/// @notice Encrypted ERC20 reward token with hidden balance tiers, private vesting
///         cliff schedules, blacklist flags, and encrypted reward multipliers per tier.
contract ConfidentialPolarisRewardToken is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public constant name = "Polaris Reward";
    string public constant symbol = "POLR";
    uint8  public constant decimals = 18;

    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _vestingBalance;
    mapping(address => euint8)  private _tier;           // 0=base,1=silver,2=gold,3=platinum
    mapping(address => euint8)  private _blacklisted;    // 1=blacklisted
    mapping(address => uint256) public  vestingCliff;
    euint64 private _totalSupply;
    euint64 private _rewardPoolBalance;

    event Transfer(address indexed from, address indexed to);
    event VestingGranted(address indexed recipient, uint256 cliff);
    event Claimed(address indexed claimant);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _rewardPoolBalance = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_rewardPoolBalance);
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
    }

    function grantVesting(address recipient, externalEuint64 encVestAmt, bytes calldata proof, uint256 cliffDays) external onlyOwner {
        euint64 vestAmt = FHE.fromExternal(encVestAmt, proof);
        if (!FHE.isInitialized(_vestingBalance[recipient])) { _vestingBalance[recipient] = FHE.asEuint64(0); FHE.allowThis(_vestingBalance[recipient]); }
        _vestingBalance[recipient] = FHE.add(_vestingBalance[recipient], vestAmt);
        vestingCliff[recipient] = block.timestamp + cliffDays * 1 days;
        FHE.allowThis(_vestingBalance[recipient]); FHE.allow(_vestingBalance[recipient], recipient);
        emit VestingGranted(recipient, vestingCliff[recipient]);
    }

    function claimVested() external whenNotPaused nonReentrant {
        require(block.timestamp >= vestingCliff[msg.sender], "Cliff not reached");
        require(FHE.isInitialized(_vestingBalance[msg.sender]), "No vesting");
        if (!FHE.isInitialized(_balances[msg.sender])) { _balances[msg.sender] = FHE.asEuint64(0); FHE.allowThis(_balances[msg.sender]); }
        _balances[msg.sender] = FHE.add(_balances[msg.sender], _vestingBalance[msg.sender]);
        _totalSupply = FHE.add(_totalSupply, _vestingBalance[msg.sender]);
        _vestingBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_vestingBalance[msg.sender]); FHE.allow(_vestingBalance[msg.sender], msg.sender);
        FHE.allowThis(_totalSupply);
        emit Claimed(msg.sender);
    }

    function setTier(address account, externalEuint8 encTier, bytes calldata proof) external onlyOwner {
        euint8 tier = FHE.fromExternal(encTier, proof);
        _tier[account] = tier;
        FHE.allowThis(_tier[account]); FHE.allow(_tier[account], account);
    }

    function setBlacklisted(address account, externalEuint8 encFlag, bytes calldata proof) external onlyOwner {
        euint8 flag = FHE.fromExternal(encFlag, proof);
        _blacklisted[account] = flag;
        FHE.allowThis(_blacklisted[account]);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external whenNotPaused nonReentrant {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool notBlacklisted = FHE.eq(_blacklisted[msg.sender], FHE.asEuint8(0));
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        ebool canTransfer = FHE.and(notBlacklisted, sufficient);
        euint64 effectiveAmt = FHE.select(canTransfer, amt, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], effectiveAmt);
        _balances[to] = FHE.add(_balances[to], effectiveAmt);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address account) external view returns (euint64) { return _balances[account]; }
    function vestingOf(address account) external view returns (euint64) { return _vestingBalance[account]; }
    function tierOf(address account) external view returns (euint8) { return _tier[account]; }
    function allowBalanceView(address account, address viewer) external onlyOwner { FHE.allow(_balances[account], viewer); }
}
