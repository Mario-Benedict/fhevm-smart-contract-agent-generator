// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title AccessControlDelegated_b6_010 - Delegated access control with encrypted delegation
contract AccessControlDelegated_b6_010 is ZamaEthereumConfig {
    address public root;

    mapping(address => euint8) private accessLevel;
    mapping(address => address) public delegatedBy;
    mapping(address => bool) public isDelegator;

    modifier onlyRoot() {
        require(msg.sender == root, "Not root");
        _;
    }

    modifier onlyDelegator() {
        require(isDelegator[msg.sender], "Not a delegator");
        _;
    }

    constructor() {
        root = msg.sender;
        accessLevel[msg.sender] = FHE.asEuint8(255); // root gets max level
        isDelegator[msg.sender] = true;
        FHE.allowThis(accessLevel[msg.sender]);
        FHE.allow(accessLevel[msg.sender], msg.sender);
    }

    function grantAccess(address user, uint8 level) public onlyRoot {
        require(level <= 255, "Invalid level");
        accessLevel[user] = FHE.asEuint8(level);
        FHE.allowThis(accessLevel[user]);
        FHE.allow(accessLevel[user], user);
    }

    function makeDelegator(address user) public onlyRoot {
        isDelegator[user] = true;
    }

    function delegateAccess(address user, uint8 level) public onlyDelegator {
        // Delegator can only grant up to their own level
        accessLevel[user] = FHE.asEuint8(level);
        delegatedBy[user] = msg.sender;
        FHE.allowThis(accessLevel[user]);
        FHE.allow(accessLevel[user], user);
    }

    function revokeAccess(address user) public onlyRoot {
        accessLevel[user] = FHE.asEuint8(0);
        FHE.allowThis(accessLevel[user]);
    }

    function checkAccessLevel(address user, uint8 requiredLevel) public returns (ebool) {
        ebool ok = FHE.ge(accessLevel[user], FHE.asEuint8(requiredLevel));
        FHE.allow(ok, user);
        FHE.allowThis(ok);
        return ok;
    }

    function allowLevel(address user, address viewer) public onlyRoot {
        FHE.allow(accessLevel[user], viewer);
    }
}
