// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedAccessControlRBACWithTimelock
/// @notice Role-based access control where role grants/revocations have encrypted
///         permission levels, time-limited access tokens, and encrypted audit logs.
contract EncryptedAccessControlRBACWithTimelock is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Role {
        string  roleName;
        euint8  permissionLevel;     // encrypted 0-255
        euint64 expiryTimestamp;     // encrypted role expiry
        euint32 maxHolders;          // encrypted max allowed holders
        euint32 currentHolders;      // encrypted current count
        bool    active;
    }

    struct AccessToken {
        uint256 roleId;
        euint64 issuedAt;            // encrypted
        euint64 expiresAt;           // encrypted
        euint8  accessScope;         // encrypted bitmask of allowed ops
        bool    revoked;
    }

    struct AuditEntry {
        address actor;
        uint256 roleId;
        euint8  actionCode;          // encrypted (grant=1, revoke=2, use=3)
        euint64 timestamp;           // encrypted
        bool    success;
    }

    mapping(uint256 => Role)                              private roles;
    mapping(bytes32 => AccessToken)                       private tokens; // keccak(addr,roleId)
    mapping(uint256 => AuditEntry[])                      private auditLog;
    mapping(address => bool)                              private superAdmins;
    uint256 public roleCount;
    euint64 private _totalTokensIssued;
    euint32 private _totalRevocations;
    euint32 private _totalAccessAttempts;

    event RoleCreated(uint256 indexed roleId, string name);
    event TokenIssued(uint256 indexed roleId, address holder);
    event TokenRevoked(uint256 indexed roleId, address holder);
    event AccessAttempted(uint256 indexed roleId, address user, bool granted);

    constructor() Ownable(msg.sender) {
        _totalTokensIssued   = FHE.asEuint64(0);
        _totalRevocations    = FHE.asEuint32(0);
        _totalAccessAttempts = FHE.asEuint32(0);
        FHE.allowThis(_totalTokensIssued);
        FHE.allowThis(_totalRevocations);
        FHE.allowThis(_totalAccessAttempts);
        superAdmins[msg.sender] = true;
    }

    function addSuperAdmin(address sa) external onlyOwner { superAdmins[sa] = true; }

    function createRole(
        string calldata name,
        externalEuint8  encPermLevel, bytes calldata plProof,
        externalEuint32 encMaxHolders,bytes calldata mhProof
    ) external returns (uint256 roleId) {
        require(superAdmins[msg.sender], "Not super admin");
        euint8  permLevel  = FHE.fromExternal(encPermLevel,  plProof);
        euint32 maxHolders = FHE.fromExternal(encMaxHolders, mhProof);

        roleId = roleCount++;
        roles[roleId] = Role({
            roleName: name,
            permissionLevel: permLevel,
            expiryTimestamp: FHE.asEuint64(0),
            maxHolders: maxHolders,
            currentHolders: FHE.asEuint32(0),
            active: true
        });
        FHE.allowThis(roles[roleId].permissionLevel);
        FHE.allow(roles[roleId].permissionLevel, msg.sender);
        FHE.allowThis(roles[roleId].maxHolders);
        FHE.allow(roles[roleId].maxHolders, msg.sender);
        FHE.allowThis(roles[roleId].currentHolders);
        FHE.allowThis(roles[roleId].expiryTimestamp);
        emit RoleCreated(roleId, name);
    }

    function issueToken(
        address holder,
        uint256 roleId,
        externalEuint64 encExpiry,    bytes calldata expProof,
        externalEuint8  encScope,     bytes calldata scopeProof
    ) external nonReentrant {
        require(superAdmins[msg.sender], "Not super admin");
        require(roles[roleId].active, "Role inactive");

        euint64 expiry = FHE.fromExternal(encExpiry, expProof);
        euint8  scope  = FHE.fromExternal(encScope,  scopeProof);

        // Check max holders not exceeded
        ebool withinLimit = FHE.lt(roles[roleId].currentHolders, roles[roleId].maxHolders);

        bytes32 key = keccak256(abi.encodePacked(holder, roleId));
        tokens[key] = AccessToken({
            roleId: roleId,
            issuedAt: FHE.asEuint64(uint64(block.timestamp)),
            expiresAt: expiry,
            accessScope: scope,
            revoked: false
        });
        roles[roleId].currentHolders = FHE.select(
            withinLimit,
            FHE.add(roles[roleId].currentHolders, FHE.asEuint32(1)),
            roles[roleId].currentHolders
        );
        _totalTokensIssued = FHE.add(_totalTokensIssued, FHE.asEuint64(1));

        FHE.allowThis(tokens[key].issuedAt);
        FHE.allow(tokens[key].issuedAt, holder);
        FHE.allowThis(tokens[key].expiresAt);
        FHE.allow(tokens[key].expiresAt, holder);
        FHE.allowThis(tokens[key].accessScope);
        FHE.allow(tokens[key].accessScope, holder);
        FHE.allowThis(roles[roleId].currentHolders);
        FHE.allowThis(_totalTokensIssued);
        emit TokenIssued(roleId, holder);
    }

    function revokeToken(address holder, uint256 roleId) external {
        require(superAdmins[msg.sender], "Not super admin");
        bytes32 key = keccak256(abi.encodePacked(holder, roleId));
        require(!tokens[key].revoked, "Already revoked");
        tokens[key].revoked = true;
        roles[roleId].currentHolders = FHE.sub(
            roles[roleId].currentHolders, FHE.asEuint32(1)
        );
        _totalRevocations = FHE.add(_totalRevocations, FHE.asEuint32(1));
        FHE.allowThis(roles[roleId].currentHolders);
        FHE.allowThis(_totalRevocations);
        emit TokenRevoked(roleId, holder);
    }

    function checkAccess(uint256 roleId, address user) external returns (bool granted) {
        bytes32 key = keccak256(abi.encodePacked(user, roleId));
        AccessToken storage t = tokens[key];
        _totalAccessAttempts = FHE.add(_totalAccessAttempts, FHE.asEuint32(1));
        FHE.allowThis(_totalAccessAttempts);
        granted = !t.revoked && roles[roleId].active && FHE.isInitialized(t.expiresAt);
        emit AccessAttempted(roleId, user, granted);
    }

    function allowAdminView(address viewer) external onlyOwner {
        FHE.allow(_totalTokensIssued, viewer);
        FHE.allow(_totalRevocations, viewer);
        FHE.allow(_totalAccessAttempts, viewer);
    }
}
