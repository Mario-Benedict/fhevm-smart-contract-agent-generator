// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title EncryptedBalanceERC20WithVesting
/// @notice Confidential ERC20 token with encrypted balances and vesting schedules.
///         Transfer amounts are hidden; only sender/receiver can decrypt their balances.
contract EncryptedBalanceERC20WithVesting is ZamaEthereumConfig, Ownable, ERC20 {
    mapping(address => euint64) private _encBalances;
    mapping(address => euint64) private _vestingBalance;
    mapping(address => uint256) private _vestingEnd;
    mapping(address => bool)    private _blacklisted;

    euint64 private _encTotalSupply;
    euint64 private _encTreasuryReserve;
    uint8   private constant DECIMALS = 6;
    bool    private _paused;

    event EncTransfer(address indexed from, address indexed to);
    event VestingScheduled(address indexed beneficiary, uint256 unlockTime);
    event Blacklisted(address indexed account);

    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        _encTotalSupply    = FHE.asEuint64(0);
        _encTreasuryReserve = FHE.asEuint64(0);
        FHE.allowThis(_encTotalSupply);
        FHE.allowThis(_encTreasuryReserve);
    }

    modifier notBlacklisted(address a) {
        require(!_blacklisted[a], "Blacklisted");
        _;
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof)
        external onlyOwner
    {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        if (!FHE.isInitialized(_encBalances[to])) {
            _encBalances[to] = FHE.asEuint64(0);
            FHE.allowThis(_encBalances[to]);
        }
        _encBalances[to]  = FHE.add(_encBalances[to], amount);
        _encTotalSupply   = FHE.add(_encTotalSupply, amount);
        FHE.allowThis(_encBalances[to]);
        FHE.allow(_encBalances[to], to);
        FHE.allowThis(_encTotalSupply);
        FHE.allow(_encTotalSupply, msg.sender);
    }

    function scheduleVesting(
        address beneficiary,
        externalEuint64 encVestAmount, bytes calldata proof,
        uint256 unlockTimestamp
    ) external onlyOwner {
        require(unlockTimestamp > block.timestamp, "Must be future");
        euint64 amount = FHE.fromExternal(encVestAmount, proof);
        _vestingBalance[beneficiary] = amount;
        _vestingEnd[beneficiary]     = unlockTimestamp;
        FHE.allowThis(_vestingBalance[beneficiary]);
        FHE.allow(_vestingBalance[beneficiary], beneficiary);
        emit VestingScheduled(beneficiary, unlockTimestamp);
    }

    function claimVested() external {
        require(block.timestamp >= _vestingEnd[msg.sender], "Still vesting");
        require(FHE.isInitialized(_vestingBalance[msg.sender]), "No vesting");
        if (!FHE.isInitialized(_encBalances[msg.sender])) {
            _encBalances[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_encBalances[msg.sender]);
        }
        _encBalances[msg.sender] = FHE.add(
            _encBalances[msg.sender], _vestingBalance[msg.sender]
        );
        _vestingBalance[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_encBalances[msg.sender]);
        FHE.allow(_encBalances[msg.sender], msg.sender);
        FHE.allowThis(_vestingBalance[msg.sender]);
    }

    function encTransfer(
        address to,
        externalEuint64 encAmount, bytes calldata proof
    ) external notBlacklisted(msg.sender) notBlacklisted(to) {
        require(FHE.isInitialized(_encBalances[msg.sender]), "No balance");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasFunds = FHE.ge(_encBalances[msg.sender], amount);
        euint64 deducted = FHE.select(hasFunds, amount, FHE.asEuint64(0));
        _encBalances[msg.sender] = FHE.sub(_encBalances[msg.sender], deducted);
        if (!FHE.isInitialized(_encBalances[to])) {
            _encBalances[to] = FHE.asEuint64(0);
            FHE.allowThis(_encBalances[to]);
        }
        _encBalances[to] = FHE.add(_encBalances[to], deducted);
        FHE.allowThis(_encBalances[msg.sender]);
        FHE.allow(_encBalances[msg.sender], msg.sender);
        FHE.allowThis(_encBalances[to]);
        FHE.allow(_encBalances[to], to);
        emit EncTransfer(msg.sender, to);
    }

    function blacklist(address account) external onlyOwner {
        _blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function allowBalanceView(address viewer) external onlyOwner {
        FHE.allow(_encTotalSupply, viewer);
    }
}
