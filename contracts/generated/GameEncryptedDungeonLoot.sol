// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameEncryptedDungeonLoot
/// @notice MMO dungeon loot system: encrypted item rarity rolls, encrypted stat multipliers,
///         encrypted player inventory value, and confidential guild treasury management.
contract GameEncryptedDungeonLoot is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }
    enum ItemType { WEAPON, ARMOR, ACCESSORY, CONSUMABLE, MATERIAL }

    struct LootItem {
        string itemName;
        ItemType itemType;
        euint8 rarityRoll;         // encrypted rarity roll 0-255
        euint64 attackBonus;       // encrypted attack stat
        euint64 defenseBonus;      // encrypted defense stat
        euint64 magicBonus;        // encrypted magic stat
        euint64 marketValue;       // encrypted estimated market value
        Rarity rarity;             // derived from roll (public for display)
        bool tradeable;
    }

    struct PlayerInventory {
        euint64 totalInventoryValue; // encrypted portfolio value
        euint64 goldBalance;         // encrypted in-game gold
        euint64 dungeonKeysOwned;    // encrypted dungeon key count
        euint64 experiencePoints;    // encrypted XP
        euint64 luckBonus;           // encrypted luck stat affecting drop rates
        mapping(uint256 => uint64) itemQuantities; // itemId => quantity (not encrypted for simplicity)
        bool registered;
    }

    struct Guild {
        string guildName;
        address guildLeader;
        euint64 treasuryGold;       // encrypted guild treasury
        euint64 totalRaidsCompleted;// encrypted raid count
        euint64 averageMemberLevel; // encrypted avg level
        uint256 memberCount;
        bool active;
    }

    struct DungeonRun {
        uint256 dungeonId;
        address[] players;
        euint64 lootDropValue;      // encrypted total loot value
        euint64 bossHealthRemaining;// encrypted boss health (for partial wins)
        euint64 rngSeed;            // encrypted RNG seed for loot determination
        bool completed;
        uint256 runTime;
    }

    mapping(uint256 => LootItem) private items;
    mapping(address => PlayerInventory) private inventories;
    mapping(uint256 => Guild) private guilds;
    mapping(uint256 => DungeonRun) private runs;
    uint256 public itemCount;
    uint256 public guildCount;
    uint256 public runCount;
    mapping(address => bool) public isGameMaster;
    euint64 private _globalLootPool;

    event ItemMinted(uint256 indexed id, string name, ItemType iType);
    event LootDropped(uint256 indexed runId, address indexed player, uint256 itemId);
    event DungeonCompleted(uint256 indexed runId);
    event GuildCreated(uint256 indexed guildId, string name);
    event PlayerRegistered(address indexed player);

    constructor() Ownable(msg.sender) {
        _globalLootPool = FHE.asEuint64(0);
        FHE.allowThis(_globalLootPool);
        isGameMaster[msg.sender] = true;
    }

    function addGameMaster(address gm) external onlyOwner { isGameMaster[gm] = true; }

    function mintItem(
        string calldata name, ItemType iType,
        externalEuint64 encAtk, bytes calldata atkProof,
        externalEuint64 encDef, bytes calldata defProof,
        externalEuint64 encMag, bytes calldata magProof,
        externalEuint64 encValue, bytes calldata vProof,
        Rarity rarity, bool tradeable
    ) external returns (uint256 id) {
        require(isGameMaster[msg.sender], "Not GM");
        euint64 atk = FHE.fromExternal(encAtk, atkProof);
        euint64 def = FHE.fromExternal(encDef, defProof);
        euint64 mag = FHE.fromExternal(encMag, magProof);
        euint64 val = FHE.fromExternal(encValue, vProof);
        // RNG for rarity roll
        euint8 rarityRoll = FHE.asEuint8(uint8(block.prevrandao % 256));
        id = itemCount++;
        items[id] = LootItem({
            itemName: name, itemType: iType, rarityRoll: rarityRoll,
            attackBonus: atk, defenseBonus: def, magicBonus: mag,
            marketValue: val, rarity: rarity, tradeable: tradeable
        });
        FHE.allowThis(items[id].rarityRoll);
        FHE.allowThis(items[id].attackBonus);
        FHE.allowThis(items[id].defenseBonus);
        FHE.allowThis(items[id].magicBonus);
        FHE.allowThis(items[id].marketValue);
        emit ItemMinted(id, name, iType);
    }

    function registerPlayer(externalEuint64 encGold, bytes calldata gProof) external {
        PlayerInventory storage inv = inventories[msg.sender];
        require(!inv.registered, "Already registered");
        euint64 gold = FHE.fromExternal(encGold, gProof);
        inv.totalInventoryValue = FHE.asEuint64(0);
        inv.goldBalance = gold;
        inv.dungeonKeysOwned = FHE.asEuint64(3); // start with 3 keys
        inv.experiencePoints = FHE.asEuint64(0);
        inv.luckBonus = FHE.randEuint64(); // random luck!
        inv.registered = true;
        FHE.allowThis(inv.totalInventoryValue);
        FHE.allowThis(inv.goldBalance);
        FHE.allowThis(inv.dungeonKeysOwned);
        FHE.allowThis(inv.experiencePoints);
        FHE.allowThis(inv.luckBonus);
        FHE.allow(inv.goldBalance, msg.sender);
        FHE.allow(inv.experiencePoints, msg.sender);
        FHE.allow(inv.luckBonus, msg.sender);
        emit PlayerRegistered(msg.sender);
    }

    function startDungeonRun(
        uint256 dungeonId,
        address[] calldata players,
        externalEuint64 encBossHealth, bytes calldata bProof
    ) external returns (uint256 runId) {
        require(isGameMaster[msg.sender], "Not GM");
        euint64 bossHealth = FHE.fromExternal(encBossHealth, bProof);
        euint64 seed = FHE.randEuint64();
        runId = runCount++;
        runs[runId] = DungeonRun({
            dungeonId: dungeonId, players: players,
            lootDropValue: FHE.asEuint64(0),
            bossHealthRemaining: bossHealth,
            rngSeed: seed,
            completed: false, runTime: block.timestamp
        });
        // Consume dungeon key for all players
        for (uint256 i = 0; i < players.length; i++) {
            PlayerInventory storage inv = inventories[players[i]];
            if (FHE.isInitialized(inv.dungeonKeysOwned)) {
                ebool hasKey = FHE.ge(inv.dungeonKeysOwned, FHE.asEuint64(1));
                inv.dungeonKeysOwned = FHE.select(hasKey,
                    FHE.sub(inv.dungeonKeysOwned, FHE.asEuint64(1)),
                    FHE.asEuint64(0));
                FHE.allowThis(inv.dungeonKeysOwned);
            }
        }
        FHE.allowThis(runs[runId].lootDropValue);
        FHE.allowThis(runs[runId].bossHealthRemaining);
        FHE.allowThis(runs[runId].rngSeed);
    }

    function completeDungeonRun(
        uint256 runId, uint256 lootItemId,
        externalEuint64 encXPGained, bytes calldata xpProof
    ) external nonReentrant {
        require(isGameMaster[msg.sender], "Not GM");
        DungeonRun storage run = runs[runId];
        require(!run.completed, "Already completed");
        euint64 xp = FHE.fromExternal(encXPGained, xpProof);
        run.completed = true;
        run.lootDropValue = items[lootItemId].marketValue;
        // Award loot and XP to all players
        for (uint256 i = 0; i < run.players.length; i++) {
            PlayerInventory storage inv = inventories[run.players[i]];
            if (inv.registered) {
                inv.experiencePoints = FHE.add(inv.experiencePoints, xp);
                inv.totalInventoryValue = FHE.add(inv.totalInventoryValue, items[lootItemId].marketValue);
                FHE.allowThis(inv.experiencePoints);
                FHE.allow(inv.experiencePoints, run.players[i]);
                FHE.allowThis(inv.totalInventoryValue);
                FHE.allow(inv.totalInventoryValue, run.players[i]);
                inv.itemQuantities[lootItemId]++;
            }
        }
        _globalLootPool = FHE.add(_globalLootPool, items[lootItemId].marketValue);
        FHE.allowThis(_globalLootPool);
        emit DungeonCompleted(runId);
    }

    function createGuild(
        string calldata name,
        externalEuint64 encTreasury, bytes calldata proof
    ) external returns (uint256 guildId) {
        euint64 treasury = FHE.fromExternal(encTreasury, proof);
        guildId = guildCount++;
        guilds[guildId] = Guild({
            guildName: name, guildLeader: msg.sender,
            treasuryGold: treasury, totalRaidsCompleted: FHE.asEuint64(0),
            averageMemberLevel: FHE.asEuint64(1), memberCount: 1, active: true
        });
        FHE.allowThis(guilds[guildId].treasuryGold);
        FHE.allowThis(guilds[guildId].totalRaidsCompleted);
        FHE.allowThis(guilds[guildId].averageMemberLevel);
        FHE.allow(guilds[guildId].treasuryGold, msg.sender);
        emit GuildCreated(guildId, name);
    }

    function tradeItem(address to, uint256 itemId, externalEuint64 encGold, bytes calldata proof) external nonReentrant {
        require(items[itemId].tradeable, "Item not tradeable");
        PlayerInventory storage seller = inventories[msg.sender];
        PlayerInventory storage buyer = inventories[to];
        require(seller.registered && buyer.registered, "Not registered");
        euint64 price = FHE.fromExternal(encGold, proof);
        ebool buyerHasFunds = FHE.ge(buyer.goldBalance, price);
        euint64 actual = FHE.select(buyerHasFunds, price, buyer.goldBalance);
        buyer.goldBalance = FHE.sub(buyer.goldBalance, actual);
        seller.goldBalance = FHE.add(seller.goldBalance, actual);
        seller.itemQuantities[itemId]--;
        buyer.itemQuantities[itemId]++;
        FHE.allowThis(buyer.goldBalance);
        FHE.allow(buyer.goldBalance, to);
        FHE.allowThis(seller.goldBalance);
        FHE.allow(seller.goldBalance, msg.sender);
    }
}
