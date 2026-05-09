// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ConfidentialInvoiceFactoring is ZamaEthereumConfig, Ownable {
    euint64 public totalLiquidity;
    mapping(uint256 => euint64) public invoiceValues;
    mapping(uint256 => euint64) public factoredAmounts;
    mapping(uint256 => ebool) public isFactored;

    constructor() Ownable(msg.sender) {
        totalLiquidity = FHE.asEuint64(0);
        FHE.allowThis(totalLiquidity);
    }

    function addLiquidity(externalEuint64 amountStr, bytes calldata proof) public onlyOwner {
        totalLiquidity = FHE.add(totalLiquidity, FHE.fromExternal(amountStr, proof));
        FHE.allowThis(totalLiquidity);
    }

    function submitInvoice(uint256 invoiceId, externalEuint64 valueStr, bytes calldata proof) public {
        invoiceValues[invoiceId] = FHE.fromExternal(valueStr, proof);
        isFactored[invoiceId] = FHE.asEbool(false);
        FHE.allowThis(invoiceValues[invoiceId]);
        FHE.allowThis(isFactored[invoiceId]);
    }

    function factorInvoice(uint256 invoiceId, externalEuint64 requestAmountStr, bytes calldata proof) public {
        euint64 requested = FHE.fromExternal(requestAmountStr, proof);
        ebool notFactored = FHE.not(isFactored[invoiceId]);
        
        // Ensure requested <= invoice value
        ebool validAmount = FHE.le(requested, invoiceValues[invoiceId]);
        
        // Ensure enough liquidity
        ebool enoughLiq = FHE.ge(totalLiquidity, requested);
        
        ebool canFactor = FHE.and(notFactored, FHE.and(validAmount, enoughLiq));
        
        euint64 actualFactored = FHE.select(canFactor, requested, FHE.asEuint64(0));
        
        factoredAmounts[invoiceId] = actualFactored;
        isFactored[invoiceId] = FHE.select(canFactor, FHE.asEbool(true), isFactored[invoiceId]);
        totalLiquidity = FHE.sub(totalLiquidity, actualFactored);

        FHE.allowThis(factoredAmounts[invoiceId]);
        FHE.allowThis(isFactored[invoiceId]);
        FHE.allowThis(totalLiquidity);
    }
}
