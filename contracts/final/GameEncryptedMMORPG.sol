// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameEncryptedMMORPG
/// @notice MMORPG where player wealth, inventory values, and guild contribution
///         are all encrypted. Players trade and battle without exposing their
///         economic position to other players.
contract GameEncryptedMMORPG is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Character {
        euint64 gold;
        euint32 experience;
        euint16 level;
        euint16 power;
        euint8 guildContributionScore;
        bool active;
    }

    struct Guild {
        string name;
        euint64 treasury;
        euint32 totalContribution;
        address guildMaster;
        address[] members;
        bool active;
    }

    struct TradeOffer {
        address seller;
        string itemName;
        euint64 askPrice;
        bool active;
    }

    mapping(address => Character) private characters;
    mapping(uint256 => Guild) private guilds;
    uint256 public guildCount;
    mapping(address => uint256) public playerGuild;
    mapping(uint256 => TradeOffer) private tradeOffers;
    uint256 public offerCount;
    euint64 private _tradingFeeBps;

    event CharacterCreated(address indexed player);
    event GuildCreated(uint256 indexed id, string name);
    event GuildJoined(address indexed player, uint256 guildId);
    event TradeOfferCreated(uint256 indexed id, address seller);
    event TradeFulfilled(uint256 indexed id, address buyer);

    constructor(externalEuint64 encTradingFee, bytes memory proof) Ownable(msg.sender) {
        _tradingFeeBps = FHE.fromExternal(encTradingFee, proof);
        FHE.allowThis(_tradingFeeBps);
    }

    function createCharacter() external {
        require(!characters[msg.sender].active, "Exists");
        characters[msg.sender] = Character({
            gold: FHE.asEuint64(1000),  // starting gold
            experience: FHE.asEuint32(0),
            level: FHE.asEuint16(1),
            power: FHE.asEuint16(10),
            guildContributionScore: FHE.asEuint8(0),
            active: true
        });
        FHE.allowThis(characters[msg.sender].gold);
        FHE.allow(characters[msg.sender].gold, msg.sender);
        FHE.allowThis(characters[msg.sender].experience);
        FHE.allow(characters[msg.sender].experience, msg.sender);
        FHE.allowThis(characters[msg.sender].level);
        FHE.allowThis(characters[msg.sender].power);
        FHE.allowThis(characters[msg.sender].guildContributionScore);
        emit CharacterCreated(msg.sender);
    }

    function createGuild(string calldata name) external returns (uint256 id) {
        require(characters[msg.sender].active, "No character");
        id = guildCount++;
        guilds[id].name = name;
        guilds[id].treasury = FHE.asEuint64(0);
        guilds[id].totalContribution = FHE.asEuint32(0);
        guilds[id].guildMaster = msg.sender;
        guilds[id].active = true;
        guilds[id].members.push(msg.sender);
        playerGuild[msg.sender] = id;
        FHE.allowThis(guilds[id].treasury);
        FHE.allowThis(guilds[id].totalContribution);
        emit GuildCreated(id, name);
    }

    function contributeToGuild(uint256 guildId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(characters[msg.sender].active, "No character");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasGold = FHE.ge(characters[msg.sender].gold, amount);
        euint64 actual = FHE.select(hasGold, amount, FHE.asEuint64(0));
        characters[msg.sender].gold = FHE.sub(characters[msg.sender].gold, actual);
        guilds[guildId].treasury = FHE.add(guilds[guildId].treasury, actual);
        characters[msg.sender].guildContributionScore = FHE.add(
            characters[msg.sender].guildContributionScore, FHE.asEuint8(1)
        );
        FHE.allowThis(characters[msg.sender].gold);
        FHE.allow(characters[msg.sender].gold, msg.sender);
        FHE.allowThis(guilds[guildId].treasury);
        FHE.allowThis(characters[msg.sender].guildContributionScore);
    }

    function createTradeOffer(string calldata itemName, externalEuint64 encPrice, bytes calldata proof) external returns (uint256 id) {
        require(characters[msg.sender].active, "No character");
        id = offerCount++;
        tradeOffers[id].seller = msg.sender;
        tradeOffers[id].itemName = itemName;
        tradeOffers[id].askPrice = FHE.fromExternal(encPrice, proof);
        tradeOffers[id].active = true;
        FHE.allowThis(tradeOffers[id].askPrice);
        emit TradeOfferCreated(id, msg.sender);
    }

    function fulfillTrade(uint256 offerId) external nonReentrant {
        TradeOffer storage offer = tradeOffers[offerId];
        require(offer.active && msg.sender != offer.seller, "Cannot buy");
        Character storage buyer = characters[msg.sender];
        ebool canAfford = FHE.ge(buyer.gold, offer.askPrice);
        euint64 actual = FHE.select(canAfford, offer.askPrice, FHE.asEuint64(0));
        euint64 fee = FHE.div(FHE.mul(actual, _tradingFeeBps), 10000); // [arithmetic_overflow_underflow]
        euint64 actualScaled = FHE.mul(actual, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 sellerReceives = FHE.sub(actual, fee);
        buyer.gold = FHE.sub(buyer.gold, actual);
        characters[offer.seller].gold = FHE.add(characters[offer.seller].gold, sellerReceives);
        if (FHE.isInitialized(canAfford)) offer.active = false;
        FHE.allowThis(buyer.gold);
        FHE.allow(buyer.gold, msg.sender);
        FHE.allowThis(characters[offer.seller].gold);
        FHE.allow(characters[offer.seller].gold, offer.seller);
        emit TradeFulfilled(offerId, msg.sender);
    }

    function allowCharacterData(address viewer) external {
        FHE.allow(characters[msg.sender].gold, viewer);
        FHE.allow(characters[msg.sender].experience, viewer);
        FHE.allow(characters[msg.sender].level, viewer);
    }
}
