// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialYieldToken
/// @notice ERC20-like token with encrypted balances, yield accrual, and vesting schedule
contract ConfidentialYieldToken is ZamaEthereumConfig, Ownable, Pausable, ReentrancyGuard {
    string public name = "Confidential Yield Token";
    string public symbol = "CYT";
    uint8 public decimals = 18;

    mapping(address => euint64) private _encryptedBalances;
    mapping(address => uint256) private _vestingStart;
    mapping(address => uint256) private _vestingDuration;
    mapping(address => euint64) private _vestedAmount;
    mapping(address => mapping(address => euint64)) private _allowances;

    euint64 private _totalSupply;
    euint64 private _yieldRate; // encrypted yield rate in basis points

    uint256 public constant YIELD_INTERVAL = 1 days;
    mapping(address => uint256) private _lastYieldClaim;

    event Transfer(address indexed from, address indexed to);
    event VestingScheduleSet(address indexed beneficiary, uint256 duration);
    event YieldClaimed(address indexed user);

    constructor(uint64 initialSupply, uint64 yieldRateBps) Ownable(msg.sender) {
        euint64 encSupply = FHE.asEuint64(uint64(initialSupply));
        _encryptedBalances[msg.sender] = encSupply;
        FHE.allowThis(_encryptedBalances[msg.sender]);
        FHE.allow(_encryptedBalances[msg.sender], msg.sender);

        _totalSupply = encSupply;
        FHE.allowThis(_totalSupply);

        _yieldRate = FHE.asEuint64(uint64(yieldRateBps));
        FHE.allowThis(_yieldRate);
        FHE.allow(_yieldRate, msg.sender);
    }

    function setVestingSchedule(
        address beneficiary,
        uint256 duration,
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external onlyOwner whenNotPaused {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        // Deduct from owner balance
        _encryptedBalances[msg.sender] = FHE.sub(_encryptedBalances[msg.sender], amount);
        FHE.allowThis(_encryptedBalances[msg.sender]);
        FHE.allow(_encryptedBalances[msg.sender], msg.sender);

        _vestedAmount[beneficiary] = amount;
        FHE.allowThis(_vestedAmount[beneficiary]);
        FHE.allow(_vestedAmount[beneficiary], beneficiary);

        _vestingStart[beneficiary] = block.timestamp;
        _vestingDuration[beneficiary] = duration;

        emit VestingScheduleSet(beneficiary, duration);
    }

    function claimVested() external whenNotPaused nonReentrant {
        require(_vestingStart[msg.sender] > 0, "No vesting schedule");
        uint256 elapsed = block.timestamp - _vestingStart[msg.sender];
        uint256 duration = _vestingDuration[msg.sender];

        // Compute vested fraction as plaintext multiplier
        uint64 fraction = elapsed >= duration ? 10000 : uint64((elapsed * 10000) / duration);
        euint64 claimable = FHE.div(FHE.mul(_vestedAmount[msg.sender], fraction), 10000);

        _encryptedBalances[msg.sender] = FHE.add(_encryptedBalances[msg.sender], claimable);
        FHE.allowThis(_encryptedBalances[msg.sender]);
        FHE.allow(_encryptedBalances[msg.sender], msg.sender);

        // Reset vested amount to zero
        _vestedAmount[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_vestedAmount[msg.sender]);
    }

    function claimYield() external whenNotPaused nonReentrant {
        uint256 elapsed = block.timestamp - _lastYieldClaim[msg.sender];
        require(elapsed >= YIELD_INTERVAL, "Too early");

        uint64 intervals = uint64(elapsed / YIELD_INTERVAL);
        // yield = balance * yieldRate * intervals / 10000
        euint64 yieldAmount = FHE.div(FHE.mul(FHE.mul(_encryptedBalances[msg.sender], _yieldRate), intervals), 10000);

        _encryptedBalances[msg.sender] = FHE.add(_encryptedBalances[msg.sender], yieldAmount);
        FHE.allowThis(_encryptedBalances[msg.sender]);
        FHE.allow(_encryptedBalances[msg.sender], msg.sender);

        _totalSupply = FHE.add(_totalSupply, yieldAmount);
        FHE.allowThis(_totalSupply);

        _lastYieldClaim[msg.sender] = block.timestamp;
        emit YieldClaimed(msg.sender);
    }

    function transfer(
        address to,
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external whenNotPaused nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        ebool hasSufficient = FHE.ge(_encryptedBalances[msg.sender], amount);
        euint64 actualAmount = FHE.select(hasSufficient, amount, FHE.asEuint64(0));

        _encryptedBalances[msg.sender] = FHE.sub(_encryptedBalances[msg.sender], actualAmount);
        _encryptedBalances[to] = FHE.add(_encryptedBalances[to], actualAmount);

        FHE.allowThis(_encryptedBalances[msg.sender]);
        FHE.allow(_encryptedBalances[msg.sender], msg.sender);
        FHE.allowThis(_encryptedBalances[to]);
        FHE.allow(_encryptedBalances[to], to);

        emit Transfer(msg.sender, to);
    }

    function approve(address spender, externalEuint64 encAmount, bytes calldata inputProof) external {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _allowances[msg.sender][spender] = amount;
        FHE.allowThis(_allowances[msg.sender][spender]);
        FHE.allow(_allowances[msg.sender][spender], spender);
    }

    function balanceOf(address account) external view returns (euint64) {
        return _encryptedBalances[account];
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
