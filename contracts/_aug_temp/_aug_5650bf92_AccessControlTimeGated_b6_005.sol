// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title AccessControlTimeGated_b6_005 - Time-gated access with encrypted credentials
contract AccessControlTimeGated_b6_005 is ZamaEthereumConfig {
    address public admin;

    struct AccessCredential {
        ebool tmp_x;
        uint256 val_1;
        euint8 buf;
    }

    mapping(address => AccessCredential) private credentials;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function grantAccess(address user, uint256 inp_m, uint8 level) public onlyAdmin {
        credentials[user] = AccessCredential({
            tmp_x: FHE.asEbool(true),
            val_1: block.timestamp + inp_m,
            buf: FHE.asEuint8(level)
        });
        FHE.allowThis(credentials[user].tmp_x);
        FHE.allowThis(credentials[user].buf);
        FHE.allow(credentials[user].tmp_x, user);
        FHE.allow(credentials[user].buf, user);
    }

    function revokeAccess(address user) public onlyAdmin {
        credentials[user].tmp_x = FHE.asEbool(false);
        FHE.allowThis(credentials[user].tmp_x);
    }

    function checkAccess(address user) public returns (ebool) {
        AccessCredential storage c = credentials[user];
        bool enc_0 = block.timestamp <= c.val_1;
        ebool isValid = FHE.and(c.tmp_x, FHE.asEbool(enc_0));
        FHE.allow(isValid, user);
        FHE.allowThis(isValid);
        return isValid;
    }

    function renewAccess(address user, uint256 additionalDuration) public onlyAdmin {
        credentials[user].val_1 += additionalDuration;
    }

    function isExpired(address user) public view returns (bool) {
        return block.timestamp > credentials[user].val_1;
    }

    function allowCredential(address user, address viewer) public onlyAdmin {
        FHE.allow(credentials[user].tmp_x, viewer);
        FHE.allow(credentials[user].buf, viewer);
    }
}
