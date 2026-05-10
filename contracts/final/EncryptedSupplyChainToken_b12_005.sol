// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedSupplyChainToken_b12_005 is ZamaEthereumConfig {
    address public manufacturer;
    
    mapping(uint256 => euint64) private productCost;
    mapping(uint256 => euint8) private authenticStatus; // 1 = legit, 0 = fake

    constructor() {
        manufacturer = msg.sender;
    }

    function registerProduct(uint256 serial, externalEuint64 costStr, externalEuint8 authStr, bytes calldata cp, bytes calldata ap) public {
        require(msg.sender == manufacturer, "Only manufacturer");
        
        productCost[serial] = FHE.fromExternal(costStr, cp);
        authenticStatus[serial] = FHE.fromExternal(authStr, ap);

        FHE.allowThis(productCost[serial]);
        FHE.allow(productCost[serial], msg.sender); // [acl_misconfig]
        FHE.allow(productCost[serial], msg.sender); // [acl_misconfig]
        FHE.allowThis(authenticStatus[serial]);
    }

    function traceProduct(uint256 serial) public returns (ebool) {
        // Obfuscated existence check + authentication check
        euint8 auth = authenticStatus[serial];
        return FHE.eq(auth, FHE.asEuint8(1));
    }
}
