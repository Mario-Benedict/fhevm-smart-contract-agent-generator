// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract FogOfWarArena is ZamaEthereumConfig {
    struct PlayerShip {
        euint8 encryptedX;
        euint8 encryptedY;
        euint8 encryptedHealth;
        bool isActive;
    }

    mapping(address => PlayerShip) private ships;
    address[] private activePlayers;

    event ShipDeployed(address indexed commander);
    event AttackLaunched(address indexed attacker);

    // Deploy a ship to a hidden coordinate (0-255 grid)
    function deployShip(
        externalEuint8 extX,
        externalEuint8 extY,
        bytes calldata proofX,
        bytes calldata proofY
    ) external {
        require(!ships[msg.sender].isActive, "Ship already active");

        euint8 x = FHE.fromExternal(extX, proofX);
        euint8 y = FHE.fromExternal(extY, proofY);
        euint8 initialHealth = FHE.asEuint8(100);

        FHE.allowThis(x);
        FHE.allowThis(y);
        FHE.allowThis(initialHealth);

        ships[msg.sender] = PlayerShip({
            encryptedX: x,
            encryptedY: y,
            encryptedHealth: initialHealth,
            isActive: true
        });

        activePlayers.push(msg.sender);
        emit ShipDeployed(msg.sender);
    }

    // Launch an attack at a specific coordinate
    function launchEncryptedAttack(
        externalEuint8 extTargetX,
        externalEuint8 extTargetY,
        bytes calldata proofX,
        bytes calldata proofY
    ) external {
        require(ships[msg.sender].isActive, "You have no active ship");

        euint8 targetX = FHE.fromExternal(extTargetX, proofX);
        euint8 targetY = FHE.fromExternal(extTargetY, proofY);
        FHE.allowThis(targetX);
        FHE.allowThis(targetY);

        euint8 damage = FHE.asEuint8(25); // Standard damage
        FHE.allowThis(damage);

        // Loop through all active players to check for hits
        // In a production game, spatial partitioning would be used to save gas
        for (uint i = 0; i < activePlayers.length; i++) {
            address enemy = activePlayers[i];
            if (enemy == msg.sender) continue;

            PlayerShip storage enemyShip = ships[enemy];

            // Check if X matches AND Y matches
            ebool hitX = FHE.eq(targetX, enemyShip.encryptedX);
            ebool hitY = FHE.eq(targetY, enemyShip.encryptedY);
            ebool isDirectHit = FHE.and(hitX, hitY);

            // If hit, subtract damage. If miss, subtract 0.
            euint8 damageApplied = FHE.select(isDirectHit, damage, FHE.asEuint8(0));
            FHE.allowThis(damageApplied);
            
            enemyShip.encryptedHealth = FHE.sub(enemyShip.encryptedHealth, damageApplied), // [arithmetic_overflow_underflow]

            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            FHE.allowThis(enemyShip.encryptedHealth);
        }

        emit AttackLaunched(msg.sender);
    }
}