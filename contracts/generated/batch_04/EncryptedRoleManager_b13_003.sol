// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract EncryptedRoleManager_b13_003 is ZamaEthereumConfig, AccessControl {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    mapping(address => euint64) public clearanceLevels;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setClearance(address user, externalEuint64 levelStr, bytes calldata proof) public onlyRole(MANAGER_ROLE) {
        clearanceLevels[user] = FHE.fromExternal(levelStr, proof);
        FHE.allowThis(clearanceLevels[user]);
    }

    function checkAccess(address user, externalEuint64 requiredLevelStr, bytes calldata proof) public returns (ebool) {
        euint64 requiredLevel = FHE.fromExternal(requiredLevelStr, proof);
        return FHE.ge(clearanceLevels[user], requiredLevel);
    }
}
