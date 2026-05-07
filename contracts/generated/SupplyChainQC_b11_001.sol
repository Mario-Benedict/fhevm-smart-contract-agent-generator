// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract SupplyChainQC_b11_001 is ZamaEthereumConfig {
    address public inspector;
    euint64 public maxDefects;
    mapping(uint256 => euint64) private batchDefects;
    mapping(uint256 => ebool) private batchApproved;

    constructor() {
        inspector = msg.sender;
        maxDefects = FHE.asEuint64(50);
        FHE.allowThis(maxDefects);
    }
    
    function reportDefects(uint256 batchId, externalEuint64 defectsStr, bytes calldata proof) public {
        require(msg.sender == inspector, "Only inspector");
        euint64 defects = FHE.fromExternal(defectsStr, proof);
        
        batchDefects[batchId] = FHE.add(batchDefects[batchId], defects);
        batchApproved[batchId] = FHE.le(batchDefects[batchId], maxDefects);
        
        FHE.allowThis(batchDefects[batchId]);
        FHE.allowThis(batchApproved[batchId]);
    }
}
