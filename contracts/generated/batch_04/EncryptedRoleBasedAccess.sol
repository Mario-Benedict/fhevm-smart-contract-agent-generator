// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedRoleBasedAccess - Enterprise RBAC with encrypted role assignments and private permission checks
contract EncryptedRoleBasedAccess is ZamaEthereumConfig, Ownable, Pausable {
    struct Role {
        string name;
        euint64 permissionsBitmask; // encrypted permission flags
        euint32 memberCount;        // encrypted member count
        bool exists;
    }

    struct UserRoles {
        euint64 combinedPermissions; // encrypted union of all role permissions
        bytes32[] assignedRoles;
        bool registered;
    }

    mapping(bytes32 => Role) private roles;
    mapping(address => UserRoles) private users;
    bytes32[] public roleList;
    mapping(address => bool) public isRoleAdmin;

    event RoleCreated(bytes32 indexed roleId, string name);
    event RoleAssigned(address indexed user, bytes32 indexed roleId);
    event RoleRevoked(address indexed user, bytes32 indexed roleId);
    event PermissionChecked(address indexed user, bool granted);

    constructor() Ownable(msg.sender) {
        isRoleAdmin[msg.sender] = true;
    }

    function addRoleAdmin(address ra) external onlyOwner { isRoleAdmin[ra] = true; }

    function createRole(string calldata name, externalEuint64 encPermissions, bytes calldata proof)
        external returns (bytes32 roleId) {
        require(isRoleAdmin[msg.sender], "Not admin");
        euint64 permissions = FHE.fromExternal(encPermissions, proof);
        roleId = keccak256(abi.encodePacked(name, block.timestamp));
        roles[roleId] = Role({ name: name, permissionsBitmask: permissions,
            memberCount: FHE.asEuint32(0), exists: true });
        FHE.allowThis(roles[roleId].permissionsBitmask);
        FHE.allowThis(roles[roleId].memberCount);
        roleList.push(roleId);
        emit RoleCreated(roleId, name);
    }

    function assignRole(address user, bytes32 roleId) external {
        require(isRoleAdmin[msg.sender], "Not admin");
        require(roles[roleId].exists, "Role not found");
        if (!users[user].registered) {
            users[user].combinedPermissions = FHE.asEuint64(0);
            users[user].registered = true;
            FHE.allowThis(users[user].combinedPermissions);
        }
        users[user].assignedRoles.push(roleId);
        // Update combined permissions with OR operation
        users[user].combinedPermissions = FHE.or(users[user].combinedPermissions, roles[roleId].permissionsBitmask);
        roles[roleId].memberCount = FHE.add(roles[roleId].memberCount, FHE.asEuint32(1));
        FHE.allowThis(users[user].combinedPermissions);
        FHE.allow(users[user].combinedPermissions, user);
        FHE.allowThis(roles[roleId].memberCount);
        emit RoleAssigned(user, roleId);
    }

    function checkPermission(address user, externalEuint64 encRequiredPerms, bytes calldata proof)
        external whenNotPaused returns (ebool granted) {
        require(users[user].registered, "Not registered");
        euint64 required = FHE.fromExternal(encRequiredPerms, proof);
        // Check if user has all required permission bits
        euint64 intersection = FHE.and(users[user].combinedPermissions, required);
        granted = FHE.eq(intersection, required);
        FHE.allow(granted, msg.sender);
        FHE.allow(granted, user);
        FHE.allowThis(granted);
        emit PermissionChecked(user, FHE.isInitialized(granted));
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function allowUserPermissions(address user, address viewer) external {
        require(isRoleAdmin[msg.sender] || msg.sender == user, "Unauthorized");
        FHE.allow(users[user].combinedPermissions, viewer);
    }

    function allowRolePermissions(bytes32 roleId, address viewer) external {
        require(isRoleAdmin[msg.sender], "Not admin");
        FHE.allow(roles[roleId].permissionsBitmask, viewer);
        FHE.allow(roles[roleId].memberCount, viewer);
    }
}
