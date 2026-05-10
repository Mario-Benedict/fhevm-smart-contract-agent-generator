// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title AccessControlGeofenced_b6_009 - Geographic access control with encrypted region codes
contract AccessControlGeofenced_b6_009 is ZamaEthereumConfig {
    address public admin;

    mapping(address => euint8) private userRegionCode;
    mapping(uint8 => ebool) private allowedRegions;
    mapping(address => ebool) private accessStatus;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
        // Enable regions 1-5 by default
        for (uint8 i = 1; i <= 5; i++) {
            allowedRegions[i] = FHE.asEbool(true);
            FHE.allowThis(allowedRegions[i]);
        }
    }

    function setUserRegion(address user, externalEuint8 regionStr, bytes calldata proof) public onlyAdmin {
        euint8 region = FHE.fromExternal(regionStr, proof);
        userRegionCode[user] = region;
        FHE.allowThis(userRegionCode[user]);
        FHE.allow(userRegionCode[user], user);
    }

    function blockRegion(uint8 regionCode) public onlyAdmin {
        allowedRegions[regionCode] = FHE.asEbool(false);
        FHE.allowThis(allowedRegions[regionCode]);
    }

    function allowRegion(uint8 regionCode) public onlyAdmin {
        allowedRegions[regionCode] = FHE.asEbool(true);
        FHE.allowThis(allowedRegions[regionCode]);
    }

    function checkAccess(address user, uint8 regionCode) public returns (ebool) {
        ebool regionAllowed = allowedRegions[regionCode];
        ebool userInRegion = FHE.eq(userRegionCode[user], FHE.asEuint8(regionCode));
        ebool canAccess = FHE.and(regionAllowed, userInRegion);
        accessStatus[user] = canAccess;
        FHE.allow(canAccess, user);
        FHE.allowThis(canAccess);
        FHE.allowThis(accessStatus[user]);
        return canAccess;
    }

    function allowUserRegion(address user, address viewer) public onlyAdmin {
        FHE.allow(userRegionCode[user], viewer);
    }
}
