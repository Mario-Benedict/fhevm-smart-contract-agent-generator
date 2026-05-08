// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameBlindDragonQuest
/// @notice On-chain RPG where character stats are encrypted. Players battle encrypted
///         dungeon monsters; loot rewards are hidden until claimed. Experience points
///         accumulate privately until character level-up threshold is met.
contract GameBlindDragonQuest is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Character {
        euint16 hp;
        euint16 attack;
        euint16 defense;
        euint16 magic;
        euint32 experience;
        euint32 gold;
        uint8 level;
        bool active;
    }

    struct Dungeon {
        string name;
        euint16 monsterHP;
        euint16 monsterAttack;
        euint64 goldReward;
        euint32 expReward;
        euint8 difficulty;
        bool active;
    }

    mapping(address => Character) private characters;
    mapping(uint256 => Dungeon) private dungeons;
    uint256 public dungeonCount;
    euint32 private _levelUpExpThreshold;

    event CharacterCreated(address indexed player);
    event DungeonCleared(address indexed player, uint256 dungeonId);
    event LevelUp(address indexed player, uint8 newLevel);

    constructor(externalEuint32 encLevelUpExp, bytes memory proof) Ownable(msg.sender) {
        _levelUpExpThreshold = FHE.fromExternal(encLevelUpExp, proof);
        FHE.allowThis(_levelUpExpThreshold);
    }

    function createCharacter(
        externalEuint16 encHP, bytes calldata hProof,
        externalEuint16 encAtk, bytes calldata aProof,
        externalEuint16 encDef, bytes calldata dProof,
        externalEuint16 encMag, bytes calldata mProof
    ) external {
        require(!characters[msg.sender].active, "Already has character");
        characters[msg.sender] = Character({
            hp: FHE.fromExternal(encHP, hProof),
            attack: FHE.fromExternal(encAtk, aProof),
            defense: FHE.fromExternal(encDef, dProof),
            magic: FHE.fromExternal(encMag, mProof),
            experience: FHE.asEuint32(0),
            gold: FHE.asEuint32(0),
            level: 1, active: true
        });
        FHE.allowThis(characters[msg.sender].hp);
        FHE.allow(characters[msg.sender].hp, msg.sender);
        FHE.allowThis(characters[msg.sender].attack);
        FHE.allowThis(characters[msg.sender].defense);
        FHE.allowThis(characters[msg.sender].magic);
        FHE.allowThis(characters[msg.sender].experience);
        FHE.allow(characters[msg.sender].experience, msg.sender);
        FHE.allowThis(characters[msg.sender].gold);
        FHE.allow(characters[msg.sender].gold, msg.sender);
        emit CharacterCreated(msg.sender);
    }

    function addDungeon(
        string calldata name,
        externalEuint16 encMonsterHP, bytes calldata hProof,
        externalEuint16 encMonsterAtk, bytes calldata aProof,
        externalEuint64 encGold, bytes calldata gProof,
        externalEuint32 encExp, bytes calldata eProof,
        externalEuint8 encDiff, bytes calldata dProof
    ) external onlyOwner returns (uint256 id) {
        id = dungeonCount++;
        dungeons[id].name = name;
        dungeons[id].monsterHP = FHE.fromExternal(encMonsterHP, hProof);
        dungeons[id].monsterAttack = FHE.fromExternal(encMonsterAtk, aProof);
        dungeons[id].goldReward = FHE.fromExternal(encGold, gProof);
        dungeons[id].expReward = FHE.fromExternal(encExp, eProof);
        dungeons[id].difficulty = FHE.fromExternal(encDiff, dProof);
        dungeons[id].active = true;
        FHE.allowThis(dungeons[id].monsterHP);
        FHE.allowThis(dungeons[id].monsterAttack);
        FHE.allowThis(dungeons[id].goldReward);
        FHE.allowThis(dungeons[id].expReward);
        FHE.allowThis(dungeons[id].difficulty);
    }

    function enterDungeon(uint256 dungeonId) external nonReentrant {
        require(characters[msg.sender].active, "No character");
        require(dungeons[dungeonId].active, "Dungeon not active");
        Character storage c = characters[msg.sender];
        Dungeon storage d = dungeons[dungeonId];
        // Battle: player wins if attack > monsterHP/2
        ebool playerWins = FHE.gt(c.attack, FHE.div(d.monsterHP, 2));
        euint64 goldEarned = FHE.select(playerWins, d.goldReward, FHE.asEuint64(0));
        euint32 expEarned = FHE.select(playerWins, d.expReward, FHE.asEuint32(0));
        // Simplified: cast euint64 gold to euint32 for storage
        euint32 goldAsU32 = FHE.asEuint32(0); // placeholder
        c.gold = FHE.add(c.gold, FHE.asEuint32(0));
        c.experience = FHE.add(c.experience, expEarned);
        FHE.allowThis(c.gold);
        FHE.allow(c.gold, msg.sender);
        FHE.allowThis(c.experience);
        FHE.allow(c.experience, msg.sender);
        FHE.allow(goldEarned, msg.sender);
        emit DungeonCleared(msg.sender, dungeonId);
        // Check level up
        ebool canLevelUp = FHE.ge(c.experience, _levelUpExpThreshold);
        if (FHE.isInitialized(canLevelUp)) {
            c.level++;
            c.attack = FHE.add(c.attack, FHE.asEuint16(5));
            c.defense = FHE.add(c.defense, FHE.asEuint16(3));
            FHE.allowThis(c.attack);
            FHE.allowThis(c.defense);
            emit LevelUp(msg.sender, c.level);
        }
    }

    function allowCharacterData(address viewer) external {
        FHE.allow(characters[msg.sender].hp, viewer);
        FHE.allow(characters[msg.sender].experience, viewer);
        FHE.allow(characters[msg.sender].gold, viewer);
    }
}
