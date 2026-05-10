// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract CloakedCompounder is ZamaEthereumConfig {
    euint64 private totalEncryptedShares;
    mapping(address => euint64) private encryptedShares;

    constructor() {
        totalEncryptedShares = FHE.asEuint64(0);
        FHE.allowThis(totalEncryptedShares);
    }

    function depositAndHide(externalEuint64 extShares, bytes calldata proof) external {
        euint64 shares = FHE.fromExternal(extShares, proof);
        FHE.allowThis(shares);

        if (!FHE.isInitialized(encryptedShares[msg.sender])) {
            encryptedShares[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(encryptedShares[msg.sender]);
        }

        encryptedShares[msg.sender] = FHE.add(encryptedShares[msg.sender], shares);
        totalEncryptedShares = FHE.add(totalEncryptedShares, shares);
        
        FHE.allowThis(encryptedShares[msg.sender]);
        FHE.allowThis(totalEncryptedShares);
    }

    // A keeper calls this to update the share ratio after compounding yield from Uniswap V3
    function compoundYieldMultiplier(externalEuint64 extMultiplier, bytes calldata proof) external {
        euint64 multiplier = FHE.fromExternal(extMultiplier, proof);
        FHE.allowThis(multiplier);
        
        // Multiplies the total value of shares opaquely
        ebool _safeMul3 = FHE.le(totalEncryptedShares, FHE.asEuint64(type(uint32).max));
        totalEncryptedShares = FHE.mul(totalEncryptedShares, multiplier);
        FHE.allowThis(totalEncryptedShares);
    }
}