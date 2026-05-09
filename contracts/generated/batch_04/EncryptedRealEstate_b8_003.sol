// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedRealEstate_b8_003 is ZamaEthereumConfig {
    
    struct Property {
        euint64 totalShares;
        euint64 sharePrice;
        address propertyManager;
        bool exists;
    }

    mapping(uint256 => Property) private properties;
    // Map property ID => User => Owned Shares
    mapping(uint256 => mapping(address => euint64)) private userShares;
    mapping(address => euint64) private pmtBalances;

    uint256 public nextPropertyId;

    function listProperty(externalEuint64 totalSharesStr, externalEuint64 priceStr, bytes calldata proofS, bytes calldata proofP) public {
        nextPropertyId++;
        euint64 totalS = FHE.fromExternal(totalSharesStr, proofS);
        euint64 price = FHE.fromExternal(priceStr, proofP);

        properties[nextPropertyId] = Property({
            totalShares: totalS,
            sharePrice: price,
            propertyManager: msg.sender,
            exists: true
        });

        // initial owner gets all hidden shares
        userShares[nextPropertyId][msg.sender] = totalS;
        
        FHE.allowThis(properties[nextPropertyId].totalShares);
        FHE.allowThis(properties[nextPropertyId].sharePrice);
        FHE.allowThis(userShares[nextPropertyId][msg.sender]);
    }

    function depositFiatToken(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amt = FHE.fromExternal(amountStr, proof);
        pmtBalances[msg.sender] = FHE.add(pmtBalances[msg.sender], amt);
        FHE.allowThis(pmtBalances[msg.sender]);
    }

    // Attempt to buy X shares directly from Property Manager confidentially
    function buySharesFromManager(uint256 propId, externalEuint64 requestedSharesStr, bytes calldata proof) public {
        require(properties[propId].exists, "Doesn't exist");
        Property storage prop = properties[propId];
        
        euint64 reqShares = FHE.fromExternal(requestedSharesStr, proof);
        
        // Cost = requested * sharePrice 
        euint64 totalCost = FHE.mul(reqShares, prop.sharePrice);

        // Conditions: buyer has enough balance AND manager has enough shares
        ebool canAfford = FHE.ge(pmtBalances[msg.sender], totalCost);
        ebool managerHasShares = FHE.ge(userShares[propId][prop.propertyManager], reqShares);
        ebool executes = FHE.and(canAfford, managerHasShares);

        euint64 actualCost = FHE.select(executes, totalCost, FHE.asEuint64(0));
        euint64 actualShares = FHE.select(executes, reqShares, FHE.asEuint64(0));

        // Adjust finances
        pmtBalances[msg.sender] = FHE.sub(pmtBalances[msg.sender], actualCost);
        pmtBalances[prop.propertyManager] = FHE.add(pmtBalances[prop.propertyManager], actualCost);

        // Adjust shares
        userShares[propId][msg.sender] = FHE.add(userShares[propId][msg.sender], actualShares);
        userShares[propId][prop.propertyManager] = FHE.sub(userShares[propId][prop.propertyManager], actualShares);

        FHE.allowThis(pmtBalances[msg.sender]);
        FHE.allowThis(pmtBalances[prop.propertyManager]);
        FHE.allowThis(userShares[propId][msg.sender]);
        FHE.allowThis(userShares[propId][prop.propertyManager]);
    }
}
