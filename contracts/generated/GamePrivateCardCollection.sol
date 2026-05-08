// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GamePrivateCardCollection
/// @notice Trading card game where card rarity and power levels are encrypted.
///         Players can sell cards without revealing their full deck composition.
contract GamePrivateCardCollection is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Rarity { Common, Uncommon, Rare, Legendary }

    struct Card {
        string name;
        Rarity rarity;
        euint16 power;
        euint16 defense;
        euint8 speed;
        uint256 cardId;
    }

    struct CardListing {
        address seller;
        uint256 cardId;
        euint64 price;
        bool active;
    }

    mapping(uint256 => Card) private cards;  // cardId -> Card
    uint256 public cardTemplateCount;
    mapping(address => mapping(uint256 => uint256)) public playerCards; // player -> templateId -> count
    mapping(address => euint64) private playerWallet;
    mapping(uint256 => CardListing) private listings;
    uint256 public listingCount;
    euint64 private _mintFeeBps;

    event CardTemplateDefined(uint256 indexed id, string name, Rarity rarity);
    event CardMinted(address indexed player, uint256 templateId);
    event CardListed(uint256 indexed listingId, address seller);
    event CardSold(uint256 indexed listingId, address buyer);

    constructor(externalEuint64 encMintFee, bytes memory proof) Ownable(msg.sender) {
        _mintFeeBps = FHE.fromExternal(encMintFee, proof);
        FHE.allowThis(_mintFeeBps);
    }

    function defineCardTemplate(
        string calldata name, Rarity rarity,
        externalEuint16 encPower, bytes calldata pProof,
        externalEuint16 encDef, bytes calldata dProof,
        externalEuint8 encSpeed, bytes calldata sProof
    ) external onlyOwner returns (uint256 id) {
        id = cardTemplateCount++;
        cards[id].name = name;
        cards[id].rarity = rarity;
        cards[id].power = FHE.fromExternal(encPower, pProof);
        cards[id].defense = FHE.fromExternal(encDef, dProof);
        cards[id].speed = FHE.fromExternal(encSpeed, sProof);
        cards[id].cardId = id;
        FHE.allowThis(cards[id].power);
        FHE.allowThis(cards[id].defense);
        FHE.allowThis(cards[id].speed);
        emit CardTemplateDefined(id, name, rarity);
    }

    function fundWallet(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        playerWallet[msg.sender] = FHE.add(playerWallet[msg.sender], amount);
        FHE.allowThis(playerWallet[msg.sender]);
        FHE.allow(playerWallet[msg.sender], msg.sender);
    }

    function mintCard(uint256 templateId, externalEuint64 encPayment, bytes calldata proof) external nonReentrant {
        require(templateId < cardTemplateCount, "Invalid template");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        euint64 fee = FHE.div(FHE.mul(payment, _mintFeeBps), 10000);
        ebool canAfford = FHE.ge(playerWallet[msg.sender], fee);
        euint64 actualFee = FHE.select(canAfford, fee, FHE.asEuint64(0));
        playerWallet[msg.sender] = FHE.sub(playerWallet[msg.sender], actualFee);
        FHE.allowThis(playerWallet[msg.sender]);
        FHE.allow(playerWallet[msg.sender], msg.sender);
        if (FHE.isInitialized(canAfford)) {
            playerCards[msg.sender][templateId]++;
        }
        emit CardMinted(msg.sender, templateId);
    }

    function listCard(uint256 templateId, externalEuint64 encPrice, bytes calldata proof) external returns (uint256 id) {
        require(playerCards[msg.sender][templateId] > 0, "Dont own card");
        id = listingCount++;
        listings[id] = CardListing({
            seller: msg.sender, cardId: templateId,
            price: FHE.fromExternal(encPrice, proof), active: true
        });
        FHE.allowThis(listings[id].price);
        playerCards[msg.sender][templateId]--;
        emit CardListed(id, msg.sender);
    }

    function buyCard(uint256 listingId) external nonReentrant {
        CardListing storage listing = listings[listingId];
        require(listing.active && msg.sender != listing.seller, "Cannot buy");
        ebool canAfford = FHE.ge(playerWallet[msg.sender], listing.price);
        euint64 actual = FHE.select(canAfford, listing.price, FHE.asEuint64(0));
        playerWallet[msg.sender] = FHE.sub(playerWallet[msg.sender], actual);
        playerWallet[listing.seller] = FHE.add(playerWallet[listing.seller], actual);
        if (FHE.isInitialized(canAfford)) {
            playerCards[msg.sender][listing.cardId]++;
            listing.active = false;
        }
        FHE.allowThis(playerWallet[msg.sender]);
        FHE.allow(playerWallet[msg.sender], msg.sender);
        FHE.allowThis(playerWallet[listing.seller]);
        FHE.allow(playerWallet[listing.seller], listing.seller);
        emit CardSold(listingId, msg.sender);
    }

    function revealCardStats(uint256 templateId, address viewer) external onlyOwner {
        FHE.allow(cards[templateId].power, viewer);
        FHE.allow(cards[templateId].defense, viewer);
        FHE.allow(cards[templateId].speed, viewer);
    }
}
