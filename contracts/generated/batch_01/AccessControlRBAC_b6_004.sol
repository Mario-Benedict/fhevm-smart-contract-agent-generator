// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title AccessControlRBAC_b6_004 - Role-based access control with encrypted permissions
contract AccessControlRBAC_b6_004 is ZamaEthereumConfig {
    address public admin;

    // Role IDs are plaintext, but permission bits are encrypted
    mapping(address => euint8) private userRoles;
    mapping(uint8 => euint8) private rolePermissions;

    uint8 public constant ROLE_VIEWER = 1;
    uint8 public constant ROLE_EDITOR = 2;
    uint8 public constant ROLE_ADMIN = 3;

    uint8 public constant PERM_READ = 1;
    uint8 public constant PERM_WRITE = 2;
    uint8 public constant PERM_DELETE = 4;
    uint8 public constant PERM_ALL = 7;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
        // Set role permissions
        rolePermissions[ROLE_VIEWER] = FHE.asEuint8(PERM_READ);
        rolePermissions[ROLE_EDITOR] = FHE.asEuint8(PERM_READ | PERM_WRITE);
        rolePermissions[ROLE_ADMIN] = FHE.asEuint8(PERM_ALL);
        for (uint8 i = 1; i <= 3; i++) {
            FHE.allowThis(rolePermissions[i]);
        }

        userRoles[msg.sender] = FHE.asEuint8(ROLE_ADMIN);
        FHE.allowThis(userRoles[msg.sender]);
    }

    function grantRole(address user, uint8 roleId) public onlyAdmin {
        require(roleId >= 1 && roleId <= 3, "Invalid role");
        userRoles[user] = FHE.asEuint8(roleId);
        FHE.allowThis(userRoles[user]);
        FHE.allow(userRoles[user], user);
    }

    function revokeRole(address user) public onlyAdmin {
        userRoles[user] = FHE.asEuint8(0);
        FHE.allowThis(userRoles[user]);
    }

    function checkPermission(address user, uint8 permission) public returns (ebool) {
        euint8 role = userRoles[user];
        euint8 perms = FHE.select(
            FHE.eq(role, FHE.asEuint8(ROLE_ADMIN)),
            rolePermissions[ROLE_ADMIN],
            FHE.select(
                FHE.eq(role, FHE.asEuint8(ROLE_EDITOR)),
                rolePermissions[ROLE_EDITOR],
                rolePermissions[ROLE_VIEWER]
            )
        );
        euint8 masked = FHE.and(perms, FHE.asEuint8(permission));
        ebool hasPermission = FHE.gt(masked, FHE.asEuint8(0));
        FHE.allow(hasPermission, user);
        FHE.allowThis(hasPermission);
        return hasPermission;
    }

    function allowRole(address user, address viewer) public onlyAdmin {
        FHE.allow(userRoles[user], viewer);
    }
}
