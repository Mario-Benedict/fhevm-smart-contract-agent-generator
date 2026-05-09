// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PrivateTokenMixer is ZamaEthereumConfig, Ownable {
    euint64 public globalLiquidity;
    mapping(address => euint64) public ghostBalances;

    constructor() Ownable(msg.sender) {
        globalLiquidity = FHE.asEuint64(0);
        FHE.allowThis(globalLiquidity);
    }

    function deposit(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amt = FHE.fromExternal(amountStr, proof);
        ghostBalances[msg.sender] = FHE.add(ghostBalances[msg.sender], amt);
        globalLiquidity = FHE.add(globalLiquidity, amt);
        
        FHE.allowThis(ghostBalances[msg.sender]);
        FHE.allowThis(globalLiquidity);
    }

    function transferPrivate(address to, externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amt = FHE.fromExternal(amountStr, proof);
        ebool valid = FHE.ge(ghostBalances[msg.sender], amt);
        
        euint64 actualTransfer = FHE.select(valid, amt, FHE.asEuint64(0));
        
        ghostBalances[msg.sender] = FHE.sub(ghostBalances[msg.sender], actualTransfer);
        ghostBalances[to] = FHE.add(ghostBalances[to], actualTransfer);

        FHE.allowThis(ghostBalances[msg.sender]);
        FHE.allowThis(ghostBalances[to]);
    }
}
