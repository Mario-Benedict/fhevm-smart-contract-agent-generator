// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateDungeonRPG - Encrypted dungeon RPG with hidden monster stats and secret loot
contract PrivateDungeonRPG is ZamaEthereumConfig, Ownable {
    struct Hero {
        euint8 attack; euint8 defense; euint8 hp; euint8 level;
        euint64 goldBalance; uint8 dungeonDepth; bool active;
    }
    struct Monster {
        euint8 hp; euint8 attack; euint8 defense; euint64 goldReward; bool defeated;
    }

    mapping(address => Hero) private heroes;
    mapping(uint256 => Monster) private monsters;
    uint256 public monsterCount;
    address public dungeonMaster;

    event HeroCreated(address indexed hero);
    event BattleResult(address indexed hero, uint256 monsterId, bool heroWon);
    event LevelUp(address indexed hero, uint8 newLevel);

    modifier onlyDM() { require(msg.sender == dungeonMaster || msg.sender == owner(), "Not DM"); _; }

    constructor(address dm) Ownable(msg.sender) { dungeonMaster = dm; }

    function createHero() external {
        heroes[msg.sender] = Hero({
            attack: FHE.asEuint8(10), defense: FHE.asEuint8(5),
            hp: FHE.asEuint8(100), level: FHE.asEuint8(1),
            goldBalance: FHE.asEuint64(0), dungeonDepth: 0, active: true
        });
        FHE.allowThis(heroes[msg.sender].attack); FHE.allow(heroes[msg.sender].attack, msg.sender);
        FHE.allowThis(heroes[msg.sender].defense); FHE.allow(heroes[msg.sender].defense, msg.sender);
        FHE.allowThis(heroes[msg.sender].hp); FHE.allow(heroes[msg.sender].hp, msg.sender);
        FHE.allowThis(heroes[msg.sender].level); FHE.allow(heroes[msg.sender].level, msg.sender);
        FHE.allowThis(heroes[msg.sender].goldBalance); FHE.allow(heroes[msg.sender].goldBalance, msg.sender);
        emit HeroCreated(msg.sender);
    }

    function spawnMonster(externalEuint8 encHP, bytes calldata hProof, externalEuint8 encAtk, bytes calldata aProof,
                          externalEuint8 encDef, bytes calldata dProof, externalEuint64 encGold, bytes calldata gProof)
        external onlyDM returns (uint256 id) {
        id = monsterCount++;
        monsters[id] = Monster({
            hp: FHE.fromExternal(encHP, hProof), attack: FHE.fromExternal(encAtk, aProof),
            defense: FHE.fromExternal(encDef, dProof), goldReward: FHE.fromExternal(encGold, gProof), defeated: false
        });
        FHE.allowThis(monsters[id].hp); FHE.allowThis(monsters[id].attack);
        FHE.allowThis(monsters[id].defense); FHE.allowThis(monsters[id].goldReward);
    }

    function battle(uint256 monsterId) external {
        require(heroes[msg.sender].active && !monsters[monsterId].defeated, "Invalid");
        Monster storage m = monsters[monsterId];
        Hero storage h = heroes[msg.sender];
        // Hero attacks: hero_attack - monster_defense = net damage to monster
        ebool heroKills = FHE.ge(h.attack, m.hp);
        m.hp = FHE.select(heroKills, FHE.asEuint8(0), FHE.sub(m.hp, h.attack));
        FHE.allowThis(m.hp);
        if (FHE.isInitialized(heroKills)) {
            m.defeated = true;
            h.goldBalance = FHE.add(h.goldBalance, m.goldReward);
            h.level = FHE.add(h.level, FHE.asEuint8(1));
            FHE.allowThis(h.goldBalance); FHE.allow(h.goldBalance, msg.sender);
            FHE.allowThis(h.level); FHE.allow(h.level, msg.sender);
            h.dungeonDepth++;
            emit LevelUp(msg.sender, h.dungeonDepth);
            emit BattleResult(msg.sender, monsterId, true);
        } else {
            // Monster counterattacks
            ebool monsterKills = FHE.ge(m.attack, h.hp);
            h.hp = FHE.select(monsterKills, FHE.asEuint8(0), FHE.sub(h.hp, m.attack));
            if (FHE.isInitialized(monsterKills)) h.active = false;
            FHE.allowThis(h.hp); FHE.allow(h.hp, msg.sender);
            emit BattleResult(msg.sender, monsterId, false);
        }
    }

    function allowHeroStats(address viewer) external {
        FHE.allow(heroes[msg.sender].hp, viewer);
        FHE.allow(heroes[msg.sender].goldBalance, viewer);
        FHE.allow(heroes[msg.sender].level, viewer);
    }
}
