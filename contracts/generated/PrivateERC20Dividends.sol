// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateERC20Dividends
/// @notice Encrypted ERC20 with dividend distribution: token holders receive encrypted dividends
///         proportional to encrypted balance snapshots, claimed on demand.
contract PrivateERC20Dividends is ZamaEthereumConfig, Ownable, Pausable {
    string public constant name = "DividendToken";
    string public constant symbol = "DVDT";

    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;
    mapping(address => mapping(address => euint64)) private _allowances;
    euint64 private _dividendPerShare;       // encrypted cumulative dividends per share * 1e9
    mapping(address => euint64) private _dividendDebt;      // encrypted already "credited"
    mapping(address => euint64) private _pendingDividends;  // encrypted unclaimed
    mapping(address => bool) public isExcludedFromDividends;
    mapping(address => bool) public isDividendDistributor;

    event Transfer(address indexed from, address indexed to);
    event DividendsDistributed();
    event DividendClaimed(address indexed holder);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _dividendPerShare = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_dividendPerShare);
        isDividendDistributor[msg.sender] = true;
        isExcludedFromDividends[msg.sender] = true;
    }

    function addDistributor(address d) external onlyOwner { isDividendDistributor[d] = true; }
    function excludeFromDividends(address a) external onlyOwner { isExcludedFromDividends[a] = true; }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _updateDividend(to);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        _dividendDebt[to] = FHE.mul(_balances[to], _dividendPerShare);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_dividendDebt[to]);
        emit Transfer(address(0), to);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external whenNotPaused {
        _updateDividend(msg.sender);
        _updateDividend(to);
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasFunds = FHE.le(amount, _balances[msg.sender]);
        euint64 actual = FHE.select(hasFunds, amount, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], actual);
        _dividendDebt[msg.sender] = FHE.mul(_balances[msg.sender], _dividendPerShare);
        _dividendDebt[to] = FHE.mul(_balances[to], _dividendPerShare);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_dividendDebt[msg.sender]);
        FHE.allowThis(_dividendDebt[to]);
        emit Transfer(msg.sender, to);
    }

    function distributeDividends(externalEuint64 encTotalDividend, bytes calldata proof) external {
        require(isDividendDistributor[msg.sender], "Not distributor");
        euint64 total = FHE.fromExternal(encTotalDividend, proof);
        // dividendPerShare += total * 1e9 / 1e6 (scaled; actual share computation deferred)
        euint64 increment = FHE.div(FHE.mul(total, FHE.asEuint64(1_000)), 1_000_000_000);
        _dividendPerShare = FHE.add(_dividendPerShare, increment);
        FHE.allowThis(_dividendPerShare);
        emit DividendsDistributed();
    }

    function _updateDividend(address holder) internal {
        if (!FHE.isInitialized(_balances[holder])) return;
        euint64 owed = FHE.sub(
            FHE.mul(_balances[holder], _dividendPerShare),
            _dividendDebt[holder]
        );
        if (!FHE.isInitialized(_pendingDividends[holder])) {
            _pendingDividends[holder] = FHE.asEuint64(0);
            FHE.allowThis(_pendingDividends[holder]);
        }
        _pendingDividends[holder] = FHE.add(_pendingDividends[holder], owed);
        _dividendDebt[holder] = FHE.mul(_balances[holder], _dividendPerShare);
        FHE.allowThis(_pendingDividends[holder]);
        FHE.allow(_pendingDividends[holder], holder);
        FHE.allowThis(_dividendDebt[holder]);
    }

    function claimDividend() external {
        _updateDividend(msg.sender);
        euint64 pending = _pendingDividends[msg.sender];
        _pendingDividends[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_pendingDividends[msg.sender]);
        FHE.allow(pending, msg.sender);
        emit DividendClaimed(msg.sender);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function allowBalance(address viewer) external {
        FHE.allow(_balances[msg.sender], viewer);
    }

    function allowDividendStats(address viewer) external onlyOwner {
        FHE.allow(_totalSupply, viewer);
        FHE.allow(_dividendPerShare, viewer);
    }
}
