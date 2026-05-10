// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCentralBankDigitalCurrency
/// @notice A CBDC system where balances and transaction amounts are encrypted.
///         Central bank can issue, freeze accounts, set velocity limits, and
///         enforce AML thresholds — all without exposing individual balances.
contract EncryptedCentralBankDigitalCurrency is ZamaEthereumConfig, AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");

    string public constant name = "Digital Fiat Token";
    string public constant symbol = "DFT";
    uint8 public constant decimals = 6;

    euint64 private _totalSupply;
    euint64 private _dailyVelocityLimit;   // max transfer per day per user

    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _dailySpent;
    mapping(address => uint256) private _lastSpendReset;
    mapping(address => bool) public frozen;
    mapping(address => bool) public kycVerified;

    event Issued(address indexed to);
    event Burned(address indexed from);
    event TransferExecuted(address indexed from, address indexed to);
    event AccountFrozen(address indexed account);
    event AccountUnfrozen(address indexed account);
    event KYCGranted(address indexed account);

    constructor(externalEuint64 encLimit, bytes memory limitProof) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
        _grantRole(FREEZER_ROLE, msg.sender);
        _dailyVelocityLimit = FHE.fromExternal(encLimit, limitProof);
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_dailyVelocityLimit);
        FHE.allowThis(_totalSupply);
    }

    modifier notFrozen(address account) {
        require(!frozen[account], "Account frozen");
        _;
    }

    modifier kycRequired(address account) {
        require(kycVerified[account], "KYC not verified");
        _;
    }

    function grantKYC(address account) external onlyRole(COMPLIANCE_ROLE) {
        kycVerified[account] = true;
        emit KYCGranted(account);
    }

    function freezeAccount(address account) external onlyRole(FREEZER_ROLE) {
        frozen[account] = true;
        emit AccountFrozen(account);
    }

    function unfreezeAccount(address account) external onlyRole(FREEZER_ROLE) {
        frozen[account] = false;
        emit AccountUnfrozen(account);
    }

    function issue(address to, externalEuint64 encAmount, bytes calldata proof)
        external onlyRole(ISSUER_ROLE) kycRequired(to) whenNotPaused
    {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
        emit Issued(to);
    }

    function burn(address from, externalEuint64 encAmount, bytes calldata proof)
        external onlyRole(ISSUER_ROLE)
    {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasBal = FHE.le(amount, _balances[from]);
        euint64 actual = FHE.select(hasBal, amount, FHE.asEuint64(0));
        ebool _safeSub182 = FHE.ge(_balances[from], actual);
        _balances[from] = FHE.select(_safeSub182, FHE.sub(_balances[from], actual), FHE.asEuint64(0));
        ebool _safeSub183 = FHE.ge(_totalSupply, actual);
        _totalSupply = FHE.select(_safeSub183, FHE.sub(_totalSupply, actual), FHE.asEuint64(0));
        FHE.allowThis(_balances[from]);
        FHE.allow(_balances[from], from);
        FHE.allowThis(_totalSupply);
        emit Burned(from);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof)
        external notFrozen(msg.sender) notFrozen(to) kycRequired(msg.sender) kycRequired(to) whenNotPaused nonReentrant
    {
        // Reset daily spend tracker if 24h has passed
        if (block.timestamp > _lastSpendReset[msg.sender] + 1 days) {
            _dailySpent[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_dailySpent[msg.sender]);
            _lastSpendReset[msg.sender] = block.timestamp;
        }
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 newSpent = FHE.add(_dailySpent[msg.sender], amount);
        ebool withinLimit = FHE.le(newSpent, _dailyVelocityLimit);
        euint64 actualTransfer = FHE.select(withinLimit, amount, FHE.asEuint64(0));
        ebool _safeSub184 = FHE.ge(_balances[msg.sender], actualTransfer);
        _balances[msg.sender] = FHE.select(_safeSub184, FHE.sub(_balances[msg.sender], actualTransfer), FHE.asEuint64(0));
        _balances[to] = FHE.add(_balances[to], actualTransfer);
        _dailySpent[msg.sender] = FHE.add(_dailySpent[msg.sender], actualTransfer);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_dailySpent[msg.sender]);
        emit TransferExecuted(msg.sender, to);
    }

    function allowBalance(address viewer) external {
        FHE.allow(_balances[msg.sender], viewer);
    }

    function allowTotalSupply(address viewer) external onlyRole(COMPLIANCE_ROLE) {
        FHE.allow(_totalSupply, viewer);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
}
