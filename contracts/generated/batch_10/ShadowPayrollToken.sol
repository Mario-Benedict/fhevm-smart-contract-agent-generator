// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ShadowPayrollToken
/// @notice Confidential ERC20 for private payroll disbursements with vesting schedule
contract ShadowPayrollToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Shadow Payroll Token";
    string public constant symbol = "SPRL";
    uint8 public constant decimals = 18;

    mapping(address => euint64) private _balances;
    mapping(address => mapping(address => euint64)) private _allowances;

    euint64 private _totalSupply;

    struct VestingSchedule {
        uint256 startTime;
        uint256 duration;
        uint256 cliffDuration;
        bool initialized;
    }

    mapping(address => VestingSchedule) public vestingSchedules;
    mapping(address => euint64) private _vestedAmounts;
    mapping(address => bool) public blacklisted;

    bool public paused;

    event Transfer(address indexed from, address indexed to);
    event Approval(address indexed owner, address indexed spender);
    event VestingCreated(address indexed employee, uint256 startTime, uint256 duration);
    event Blacklisted(address indexed account);

    modifier notPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    modifier notBlacklisted(address account) {
        require(!blacklisted[account], "Account is blacklisted");
        _;
    }

    constructor() Ownable(msg.sender) {
        euint64 initialSupply = FHE.asEuint64(0);
        _totalSupply = initialSupply;
        FHE.allowThis(_totalSupply);
    }

    function mint(address to, externalEuint64 encryptedAmount, bytes calldata inputProof)
        external
        onlyOwner
        notPaused
        notBlacklisted(to)
    {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allowThis(_totalSupply);
        FHE.allow(_balances[to], to);
        emit Transfer(address(0), to);
    }

    function transfer(address to, externalEuint64 encryptedAmount, bytes calldata inputProof)
        external
        notPaused
        notBlacklisted(msg.sender)
        notBlacklisted(to)
        nonReentrant
    {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        euint64 senderBalance = _balances[msg.sender];
        ebool canTransfer = FHE.le(amount, senderBalance);
        euint64 actualAmount = FHE.select(canTransfer, amount, FHE.asEuint64(0));

        _balances[msg.sender] = FHE.sub(senderBalance, actualAmount);
        _balances[to] = FHE.add(_balances[to], actualAmount);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[to], to);

        emit Transfer(msg.sender, to);
    }

    function createVestingSchedule(address employee, uint256 startTime, uint256 duration, uint256 cliffDuration)
        external
        onlyOwner
    {
        require(!vestingSchedules[employee].initialized, "Schedule exists");
        vestingSchedules[employee] = VestingSchedule(startTime, duration, cliffDuration, true);
        emit VestingCreated(employee, startTime, duration);
    }

    function claimVested() external notPaused notBlacklisted(msg.sender) nonReentrant {
        VestingSchedule memory schedule = vestingSchedules[msg.sender];
        require(schedule.initialized, "No vesting schedule");
        require(block.timestamp >= schedule.startTime + schedule.cliffDuration, "Cliff not reached");

        uint256 elapsed = block.timestamp - schedule.startTime;
        uint256 vestedFraction = elapsed >= schedule.duration ? 100 : (elapsed * 100) / schedule.duration;

        euint64 total = _vestedAmounts[msg.sender];
        euint64 vestedAmount = FHE.div(FHE.mul(total, uint64(vestedFraction)), 100);
        euint64 claimable = FHE.sub(vestedAmount, _balances[msg.sender]);

        ebool hasClaimable = FHE.gt(claimable, FHE.asEuint64(0));
        euint64 actualClaim = FHE.select(hasClaimable, claimable, FHE.asEuint64(0));

        _balances[msg.sender] = FHE.add(_balances[msg.sender], actualClaim);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
    }

    function blacklist(address account) external onlyOwner {
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }
}
