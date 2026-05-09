// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingRPGStats_b5_007 - Encrypted RPG character stats
contract GamingRPGStats_b5_007 is ZamaEthereumConfig {
    address public gamemaster;

    struct Character {
        string name;
        euint8 strength;
        euint8 agility;
        euint8 intelligence;
        euint8 luck;
        euint32 experience;
        bool exists;
    }

    mapping(address => Character) private characters;
    mapping(address => bool) public hasCharacter;

    modifier onlyGamemaster() {
        require(msg.sender == gamemaster, "Not gamemaster");
        _;
    }

    constructor() {
        gamemaster = msg.sender;
    }

    function createCharacter(string calldata name) public {
        require(!hasCharacter[msg.sender], "Already has character");
        hasCharacter[msg.sender] = true;
        characters[msg.sender] = Character({
            name: name,
            strength: FHE.randEuint8(),
            agility: FHE.randEuint8(),
            intelligence: FHE.randEuint8(),
            luck: FHE.randEuint8(),
            experience: FHE.asEuint32(0),
            exists: true
        });
        Character storage c = characters[msg.sender];
        FHE.allowThis(c.strength);
        FHE.allowThis(c.agility);
        FHE.allowThis(c.intelligence);
        FHE.allowThis(c.luck);
        FHE.allowThis(c.experience);
        FHE.allow(c.strength, msg.sender);
        FHE.allow(c.agility, msg.sender);
        FHE.allow(c.intelligence, msg.sender);
        FHE.allow(c.luck, msg.sender);
    }

    function gainExperience(address player, externalEuint32 xpStr, bytes calldata proof) public onlyGamemaster {
        require(hasCharacter[player], "No character");
        euint32 xp = FHE.fromExternal(xpStr, proof);
        characters[player].experience = FHE.add(characters[player].experience, xp);
        FHE.allowThis(characters[player].experience);
        FHE.allow(characters[player].experience, player);
    }

    function upgradeStats(externalEuint8 statStr, bytes calldata proof, uint8 statType) public {
        require(hasCharacter[msg.sender], "No character");
        euint8 boost = FHE.fromExternal(statStr, proof);
        Character storage c = characters[msg.sender];
        if (statType == 0) { c.strength = FHE.add(c.strength, boost); FHE.allowThis(c.strength); }
        else if (statType == 1) { c.agility = FHE.add(c.agility, boost); FHE.allowThis(c.agility); }
        else if (statType == 2) { c.intelligence = FHE.add(c.intelligence, boost); FHE.allowThis(c.intelligence); }
        else if (statType == 3) { c.luck = FHE.add(c.luck, boost); FHE.allowThis(c.luck); }
    }

    function allowStats(address viewer) public {
        require(hasCharacter[msg.sender], "No character");
        Character storage c = characters[msg.sender];
        FHE.allow(c.strength, viewer);
        FHE.allow(c.agility, viewer);
        FHE.allow(c.intelligence, viewer);
        FHE.allow(c.luck, viewer);
    }
}
