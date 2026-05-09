// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract MysticLootBox is ZamaEthereumConfig {
    uint256 public constant BOX_PRICE = 0.05 ether;

    struct EncryptedInventory {
        euint64 itemTier1; // Common
        euint64 itemTier2; // Rare
        euint64 itemTier3; // Legendary
    }

    mapping(address => EncryptedInventory) private inventories;

    event LootBoxPurchased(address indexed player);
    event ItemRevealed(address indexed player, uint64 tier);

    function _initInventory(address user) internal {
        if (!FHE.isInitialized(inventories[user].itemTier1)) {
            inventories[user].itemTier1 = FHE.asEuint64(0);
            inventories[user].itemTier2 = FHE.asEuint64(0);
            inventories[user].itemTier3 = FHE.asEuint64(0);
            
            FHE.allowThis(inventories[user].itemTier1);
            FHE.allowThis(inventories[user].itemTier2);
            FHE.allowThis(inventories[user].itemTier3);
        }
    }

    function buyLootBox() external payable {
        require(msg.value == BOX_PRICE, "Incorrect ETH amount");
        _initInventory(msg.sender);

        // Generate encrypted random number
        euint64 randomValue = FHE.randEuint64();
        
        // Map random value to a tier (Simplified: modulo 100 for percentage)
        euint64 roll = FHE.rem(randomValue, 100);
        FHE.allowThis(roll);

        // Tier Logic: 
        // Legendary (< 5), Rare (< 30), Common (>= 30)
        ebool isLegendary = FHE.lt(roll, FHE.asEuint64(5));
        ebool isRare = FHE.and(FHE.ge(roll, FHE.asEuint64(5)), FHE.lt(roll, FHE.asEuint64(30)));
        ebool isCommon = FHE.ge(roll, FHE.asEuint64(30));

        // Add 1 to the corresponding tier inventory opaquely
        euint64 addLegendary = FHE.select(isLegendary, FHE.asEuint64(1), FHE.asEuint64(0));
        euint64 addRare = FHE.select(isRare, FHE.asEuint64(1), FHE.asEuint64(0));
        euint64 addCommon = FHE.select(isCommon, FHE.asEuint64(1), FHE.asEuint64(0));

        FHE.allowThis(addLegendary);
        FHE.allowThis(addRare);
        FHE.allowThis(addCommon);

        inventories[msg.sender].itemTier3 = FHE.add(inventories[msg.sender].itemTier3, addLegendary);
        inventories[msg.sender].itemTier2 = FHE.add(inventories[msg.sender].itemTier2, addRare);
        inventories[msg.sender].itemTier1 = FHE.add(inventories[msg.sender].itemTier1, addCommon);

        FHE.allowThis(inventories[msg.sender].itemTier3);
        FHE.allowThis(inventories[msg.sender].itemTier2);
        FHE.allowThis(inventories[msg.sender].itemTier1);

        emit LootBoxPurchased(msg.sender);
    }

    // Allow user to decrypt their balance to UI
    function viewMyEncryptedLegendaries() external view returns (euint64) {
        return inventories[msg.sender].itemTier3;
    }
}