// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ConfidentialGridEnergyTrade is ZamaEthereumConfig, Ownable {
    mapping(address => euint64) public energyCredits;
    mapping(address => euint64) public fiatBalances;
    
    euint64 public currentPricePerUnit;

    constructor() Ownable(msg.sender) {
        currentPricePerUnit = FHE.asEuint64(5); // 5 fiat units per energy unit
        FHE.allowThis(currentPricePerUnit);
    }

    function setPrice(externalEuint64 priceStr, bytes calldata proof) public onlyOwner {
        currentPricePerUnit = FHE.fromExternal(priceStr, proof);
        FHE.allowThis(currentPricePerUnit);
    }

    function mintEnergy(address producer, externalEuint64 eStr, bytes calldata proof) public onlyOwner {
        energyCredits[producer] = FHE.add(energyCredits[producer], FHE.fromExternal(eStr, proof));
        FHE.allowThis(energyCredits[producer]);
    }

    function fundFiat(address buyer, externalEuint64 fStr, bytes calldata proof) public onlyOwner {
        fiatBalances[buyer] = FHE.add(fiatBalances[buyer], FHE.fromExternal(fStr, proof));
        FHE.allowThis(fiatBalances[buyer]);
    }

    function buyEnergy(address seller, externalEuint64 unitsRequestedStr, bytes calldata proof) public {
        euint64 requested = FHE.fromExternal(unitsRequestedStr, proof);
        
        euint64 totalCost = FHE.mul(requested, currentPricePerUnit);
        
        ebool sellerHasEnergy = FHE.ge(energyCredits[seller], requested);
        ebool buyerHasFiat = FHE.ge(fiatBalances[msg.sender], totalCost);
        
        ebool canTrade = FHE.and(sellerHasEnergy, buyerHasFiat);
        
        euint64 actualEnergy = FHE.select(canTrade, requested, FHE.asEuint64(0));
        euint64 actualCost = FHE.select(canTrade, totalCost, FHE.asEuint64(0));

        energyCredits[seller] = FHE.sub(energyCredits[seller], actualEnergy);
        energyCredits[msg.sender] = FHE.add(energyCredits[msg.sender], actualEnergy);
        
        fiatBalances[msg.sender] = FHE.sub(fiatBalances[msg.sender], actualCost);
        fiatBalances[seller] = FHE.add(fiatBalances[seller], actualCost);

        FHE.allowThis(energyCredits[seller]);
        FHE.allowThis(energyCredits[msg.sender]);
        FHE.allowThis(fiatBalances[seller]);
        FHE.allowThis(fiatBalances[msg.sender]);
    }
}
