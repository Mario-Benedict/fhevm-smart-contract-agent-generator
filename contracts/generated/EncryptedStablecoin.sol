// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedStablecoin
/// @notice Stablecoin with encrypted balances, blacklist functionality, and collateral tracking
contract EncryptedStablecoin is ZamaEthereumConfig, AccessControl, Pausable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    string public name = "Encrypted Stablecoin";
    string public symbol = "EUSD";
    uint8 public decimals = 6;

    mapping(address => euint32) private _balances;
    mapping(address => bool) private _blacklisted;
    mapping(address => euint32) private _frozenBalances;
    mapping(address => mapping(address => euint32)) private _allowances;

    euint32 private _totalSupply;
    uint256 public collateralRatio = 15000; // 150% in basis points

    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);
    event Frozen(address indexed account);
    event Mint(address indexed to);
    event Burn(address indexed from);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BLACKLISTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        _totalSupply = FHE.asEuint32(0);
        FHE.allowThis(_totalSupply);
    }

    modifier notBlacklisted(address account) {
        require(!_blacklisted[account], "Account is blacklisted");
        _;
    }

    function mint(address to, externalEuint32 calldata encAmount, bytes calldata inputProof)
        external onlyRole(MINTER_ROLE) whenNotPaused notBlacklisted(to)
    {
        euint32 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);

        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);

        emit Mint(to);
    }

    function burn(externalEuint32 calldata encAmount, bytes calldata inputProof)
        external whenNotPaused notBlacklisted(msg.sender)
    {
        euint32 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_balances[msg.sender], amount);
        euint32 actual = FHE.select(sufficient, amount, FHE.asEuint32(0));

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _totalSupply = FHE.sub(_totalSupply, actual);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_totalSupply);

        emit Burn(msg.sender);
    }

    function transfer(address to, externalEuint32 calldata encAmount, bytes calldata inputProof)
        external whenNotPaused notBlacklisted(msg.sender) notBlacklisted(to)
    {
        euint32 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_balances[msg.sender], amount);
        euint32 actual = FHE.select(sufficient, amount, FHE.asEuint32(0));

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], actual);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function freezeBalance(address account, externalEuint32 calldata encAmount, bytes calldata inputProof)
        external onlyRole(BLACKLISTER_ROLE)
    {
        euint32 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_balances[account], amount);
        euint32 actual = FHE.select(sufficient, amount, FHE.asEuint32(0));

        _balances[account] = FHE.sub(_balances[account], actual);
        _frozenBalances[account] = FHE.add(_frozenBalances[account], actual);

        FHE.allowThis(_balances[account]);
        FHE.allow(_balances[account], account);
        FHE.allowThis(_frozenBalances[account]);

        emit Frozen(account);
    }

    function blacklist(address account) external onlyRole(BLACKLISTER_ROLE) {
        _blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function unblacklist(address account) external onlyRole(BLACKLISTER_ROLE) {
        _blacklisted[account] = false;
        emit Unblacklisted(account);
    }

    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    function balanceOf(address account) external view returns (euint32) {
        return _balances[account];
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
}
