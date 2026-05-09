// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title EmberCoinToken - Confidential ERC20 with compliance blacklist
contract EmberCoinToken is ZamaEthereumConfig, AccessControl {
    string public constant name = "EmberCoin";
    string public constant symbol = "EMB";

    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    mapping(address => euint32) private _balances;
    mapping(address => bool) public blacklisted;

    event Transfer(address indexed from, address indexed to);
    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    modifier notBlacklisted(address account) {
        require(!blacklisted[account], "Blacklisted");
        _;
    }

    function mint(address to, externalEuint32 encAmount, bytes calldata inputProof)
        external
        onlyRole(MINTER_ROLE)
        notBlacklisted(to)
    {
        euint32 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[to] = FHE.add(_balances[to], amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        emit Transfer(address(0), to);
    }

    function transfer(address to, externalEuint32 encAmount, bytes calldata inputProof)
        external
        notBlacklisted(msg.sender)
        notBlacklisted(to)
    {
        euint32 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], amount);
        _balances[to] = FHE.add(_balances[to], amount);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function blacklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function unblacklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        blacklisted[account] = false;
        emit Unblacklisted(account);
    }

    function balanceOf(address account) external view returns (euint32) {
        return _balances[account];
    }
}
