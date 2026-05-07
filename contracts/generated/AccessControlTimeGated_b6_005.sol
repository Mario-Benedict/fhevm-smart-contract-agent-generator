// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title AccessControlTimeGated_b6_005 - Time-gated access with encrypted credentials
contract AccessControlTimeGated_b6_005 is ZamaEthereumConfig {
    address public admin;

    struct AccessCredential {
        ebool active;
        uint256 expiresAt;
        euint8 accessLevel;
    }

    mapping(address => AccessCredential) private credentials;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function grantAccess(address user, uint256 duration, uint8 level) public onlyAdmin {
        credentials[user] = AccessCredential({
            active: FHE.asEbool(true),
            expiresAt: block.timestamp + duration,
            accessLevel: FHE.asEuint8(level)
        });
        FHE.allowThis(credentials[user].active);
        FHE.allowThis(credentials[user].accessLevel);
        FHE.allow(credentials[user].active, user);
        FHE.allow(credentials[user].accessLevel, user);
    }

    function revokeAccess(address user) public onlyAdmin {
        credentials[user].active = FHE.asEbool(false);
        FHE.allowThis(credentials[user].active);
    }

    function checkAccess(address user) public returns (ebool) {
        AccessCredential storage c = credentials[user];
        bool notExpired = block.timestamp <= c.expiresAt;
        ebool isValid = FHE.and(c.active, FHE.asEbool(notExpired));
        FHE.allow(isValid, user);
        FHE.allowThis(isValid);
        return isValid;
    }

    function renewAccess(address user, uint256 additionalDuration) public onlyAdmin {
        credentials[user].expiresAt += additionalDuration;
    }

    function isExpired(address user) public view returns (bool) {
        return block.timestamp > credentials[user].expiresAt;
    }

    function allowCredential(address user, address viewer) public onlyAdmin {
        FHE.allow(credentials[user].active, viewer);
        FHE.allow(credentials[user].accessLevel, viewer);
    }
}
