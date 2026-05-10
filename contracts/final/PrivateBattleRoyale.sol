// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateBattleRoyale - Battle royale game with encrypted HP, armor, and loot values
contract PrivateBattleRoyale is ZamaEthereumConfig, Ownable {
    struct Contestant {
        euint8 hp;           // encrypted health 0-100
        euint8 armor;        // encrypted armor 0-50
        euint64 lootValue;   // encrypted accumulated loot
        uint8 kills;
        bool alive;
        bool registered;
    }

    mapping(address => Contestant) private contestants;
    address[] public playerList;
    euint64 private _totalPrizePool;
    bool public gameActive;
    uint8 public aliveCount;
    address public gamemaster;

    event GameStarted();
    event PlayerEliminated(address indexed player, address killer);
    event LootDropped(address indexed player);
    event GameEnded(address winner);

    modifier onlyGamemaster() {
        require(msg.sender == gamemaster || msg.sender == owner(), "Not gamemaster");
        _;
    }

    constructor(address gm) Ownable(msg.sender) {
        gamemaster = gm;
        _totalPrizePool = FHE.asEuint64(0);
        FHE.allowThis(_totalPrizePool);
    }

    function register(externalEuint64 encEntry, bytes calldata proof) external {
        require(!gameActive, "Game started");
        euint64 entry = FHE.fromExternal(encEntry, proof);
        uint8 startHP = 100; uint8 startArmor = 20;
        contestants[msg.sender] = Contestant({
            hp: FHE.asEuint8(startHP), armor: FHE.asEuint8(startArmor),
            lootValue: FHE.asEuint64(0), kills: 0, alive: true, registered: true
        });
        FHE.allowThis(contestants[msg.sender].hp);
        FHE.allow(contestants[msg.sender].hp, msg.sender);
        FHE.allowThis(contestants[msg.sender].armor);
        FHE.allow(contestants[msg.sender].armor, msg.sender);
        FHE.allowThis(contestants[msg.sender].lootValue);
        FHE.allow(contestants[msg.sender].lootValue, msg.sender);
        _totalPrizePool = FHE.add(_totalPrizePool, entry);
        FHE.allowThis(_totalPrizePool);
        playerList.push(msg.sender);
        aliveCount++;
    }

    function startGame() external onlyGamemaster { gameActive = true; emit GameStarted(); }

    function applyDamage(address target, externalEuint8 encDmg, bytes calldata proof) external {
        require(gameActive && contestants[msg.sender].alive, "Invalid");
        require(contestants[target].alive, "Target dead");
        euint8 dmg = FHE.fromExternal(encDmg, proof);
        // Net damage after armor
        euint8 netDmg = FHE.sub(dmg, contestants[target].armor);
        ebool killed = FHE.ge(netDmg, contestants[target].hp);
        contestants[target].hp = FHE.select(killed, FHE.asEuint8(0), FHE.sub(contestants[target].hp, netDmg));
        FHE.allowThis(contestants[target].hp);
        FHE.allow(contestants[target].hp, target);
        if (FHE.isInitialized(killed)) {
            contestants[target].alive = false;
            contestants[msg.sender].kills++;
            contestants[msg.sender].lootValue = FHE.add(contestants[msg.sender].lootValue, contestants[target].lootValue);
            FHE.allowThis(contestants[msg.sender].lootValue);
            FHE.allow(contestants[msg.sender].lootValue, msg.sender);
            aliveCount--;
            emit PlayerEliminated(target, msg.sender);
        }
    }

    function dropLoot(address player, externalEuint64 encLoot, bytes calldata proof) external onlyGamemaster {
        euint64 loot = FHE.fromExternal(encLoot, proof);
        contestants[player].lootValue = FHE.add(contestants[player].lootValue, loot);
        FHE.allowThis(contestants[player].lootValue);
        FHE.allow(contestants[player].lootValue, player);
        emit LootDropped(player);
    }

    function endGame(address winner) external onlyGamemaster {
        require(aliveCount <= 1, "Game ongoing");
        gameActive = false;
        FHE.allow(_totalPrizePool, winner);
        emit GameEnded(winner);
    }

    function healSelf(externalEuint8 encAmount, bytes calldata proof) external {
        require(gameActive && contestants[msg.sender].alive, "Invalid");
        euint8 heal = FHE.fromExternal(encAmount, proof);
        contestants[msg.sender].hp = FHE.add(contestants[msg.sender].hp, heal);
        // Cap at 100
        ebool over100 = FHE.gt(contestants[msg.sender].hp, FHE.asEuint8(100));
        contestants[msg.sender].hp = FHE.select(over100, FHE.asEuint8(100), contestants[msg.sender].hp);
        FHE.allowThis(contestants[msg.sender].hp);
        FHE.allow(contestants[msg.sender].hp, msg.sender);
    }

    function allowStats(address viewer) external {
        FHE.allow(contestants[msg.sender].hp, viewer);
        FHE.allow(contestants[msg.sender].lootValue, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}