// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedSupplyChain_b7_002 is ZamaEthereumConfig {
    
    struct ProductBatch {
        euint64 productionCost;
        euint64 cumulativeMarkup;
        address currentOwner;
        bool exists;
    }

    mapping(uint256 => ProductBatch) private batches;
    uint256 public batchCounter;

    function manufactureProduct(externalEuint64 costStr, bytes calldata proof) public returns (uint256) {
        euint64 pCost = FHE.fromExternal(costStr, proof);
        
        batchCounter++;
        batches[batchCounter] = ProductBatch({
            productionCost: pCost,
            cumulativeMarkup: FHE.asEuint64(0),
            currentOwner: msg.sender,
            exists: true
        });

        FHE.allowThis(batches[batchCounter].productionCost);
        FHE.allowThis(batches[batchCounter].cumulativeMarkup);
        return batchCounter;
    }

    function transferAndMarkup(uint256 batchId, address nextOwner, externalEuint64 markupStr, bytes calldata proof) public {
        ProductBatch storage batch = batches[batchId];
        require(batch.exists, "Batch not found");
        require(batch.currentOwner == msg.sender, "Not owner");

        euint64 markup = FHE.fromExternal(markupStr, proof);
        
        batch.cumulativeMarkup = FHE.add(batch.cumulativeMarkup, markup);
        batch.currentOwner = nextOwner;

        FHE.allowThis(batch.cumulativeMarkup);
    }

    function revealWholesalePrice(uint256 batchId) public returns (euint64) {
        ProductBatch storage batch = batches[batchId];
        require(batch.currentOwner == msg.sender, "Only current owner can compute");
        
        // Final wholesale price is production cost + all intermediary markups
        return FHE.add(batch.productionCost, batch.cumulativeMarkup);
    }
}
