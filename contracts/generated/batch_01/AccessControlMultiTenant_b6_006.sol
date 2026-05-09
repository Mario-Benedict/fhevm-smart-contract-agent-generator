// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title AccessControlMultiTenant_b6_006 - Multi-tenant encrypted resource ACL
contract AccessControlMultiTenant_b6_006 is ZamaEthereumConfig {
    address public platformAdmin;

    struct Tenant {
        string name;
        ebool active;
        euint8 tier; // 1=basic, 2=pro, 3=enterprise
        uint256 expiresAt;
    }

    mapping(address => Tenant) private tenants;
    mapping(address => mapping(string => ebool)) private resourceAccess;

    modifier onlyPlatformAdmin() {
        require(msg.sender == platformAdmin, "Not platform admin");
        _;
    }

    constructor() {
        platformAdmin = msg.sender;
    }

    function registerTenant(address tenant, string calldata name, uint8 tier, uint256 duration) public onlyPlatformAdmin {
        tenants[tenant] = Tenant({
            name: name,
            active: FHE.asEbool(true),
            tier: FHE.asEuint8(tier),
            expiresAt: block.timestamp + duration
        });
        FHE.allowThis(tenants[tenant].active);
        FHE.allowThis(tenants[tenant].tier);
        FHE.allow(tenants[tenant].active, tenant);
        FHE.allow(tenants[tenant].tier, tenant);
    }

    function suspendTenant(address tenant) public onlyPlatformAdmin {
        tenants[tenant].active = FHE.asEbool(false);
        FHE.allowThis(tenants[tenant].active);
    }

    function grantResourceAccess(address tenant, string calldata resourceId) public onlyPlatformAdmin {
        resourceAccess[tenant][resourceId] = FHE.asEbool(true);
        FHE.allowThis(resourceAccess[tenant][resourceId]);
        FHE.allow(resourceAccess[tenant][resourceId], tenant);
    }

    function revokeResourceAccess(address tenant, string calldata resourceId) public onlyPlatformAdmin {
        resourceAccess[tenant][resourceId] = FHE.asEbool(false);
        FHE.allowThis(resourceAccess[tenant][resourceId]);
    }

    function checkResourceAccess(address tenant, string calldata resourceId) public returns (ebool) {
        bool notExpired = block.timestamp <= tenants[tenant].expiresAt;
        ebool hasAccess = FHE.and(
            FHE.and(tenants[tenant].active, FHE.asEbool(notExpired)),
            resourceAccess[tenant][resourceId]
        );
        FHE.allow(hasAccess, tenant);
        FHE.allowThis(hasAccess);
        return hasAccess;
    }

    function allowTenantInfo(address tenant, address viewer) public onlyPlatformAdmin {
        FHE.allow(tenants[tenant].active, viewer);
        FHE.allow(tenants[tenant].tier, viewer);
    }
}
