// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract AccessControlWhitelist_b3_001 is ZamaEthereumConfig {
    mapping(address => ebool) private isWhitelisted;
    address public admin;

    constructor() {
        admin = msg.sender;
    }

    function addWhitelist(address user, externalEbool flagStr, bytes calldata inputProof) public {
        require(msg.sender == admin, "Not admin");
        ebool flag = FHE.fromExternal(flagStr, inputProof);
        isWhitelisted[user] = flag;
        FHE.allowThis(isWhitelisted[user]);
    }

    function checkWhitelist(address user) public view returns (ebool) {
        return isWhitelisted[user];
    }
}
