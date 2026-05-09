// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ERC20OZAccessControl_c2_002
/// @notice Confidential ERC20 with OpenZeppelin AccessControl:
///         MINTER_ROLE, PAUSER_ROLE, COMPLIANCE_ROLE with encrypted balances.
contract ERC20OZAccessControl_c2_002 is ZamaEthereumConfig, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    string public name = "Regulated Confi Token";
    string public symbol = "RCT";

    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;
    mapping(address => ebool) private _frozen; // compliance freeze

    event AccountFrozen(address indexed account);
    event AccountUnfrozen(address indexed account);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof)
        external onlyRole(MINTER_ROLE)
    {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
    }

    function freeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        _frozen[account] = FHE.asEbool(true);
        FHE.allowThis(_frozen[account]);
        emit AccountFrozen(account);
    }

    function unfreeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        _frozen[account] = FHE.asEbool(false);
        FHE.allowThis(_frozen[account]);
        emit AccountUnfrozen(account);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Only transfer if sender is not frozen
        ebool notFrozen = FHE.not(_frozen[msg.sender]);
        ebool hasFunds = FHE.le(amount, _balances[msg.sender]);
        ebool canTransfer = FHE.and(notFrozen, hasFunds);
        euint64 actual = FHE.select(canTransfer, amount, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], actual);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function complianceSeize(address from, externalEuint64 encAmount, bytes calldata proof)
        external onlyRole(COMPLIANCE_ROLE)
    {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, _balances[from]);
        euint64 seized = FHE.select(ok, amount, _balances[from]);
        _balances[from] = FHE.sub(_balances[from], seized);
        _balances[msg.sender] = FHE.add(_balances[msg.sender], seized);
        FHE.allowThis(_balances[from]);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
    }

    function allowBalance(address viewer) external {
        FHE.allow(_balances[msg.sender], viewer);
    }
}
