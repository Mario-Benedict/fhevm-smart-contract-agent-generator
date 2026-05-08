// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateSecondhandLuxuryAuthentication
/// @notice Luxury resale authentication: encrypted authentication scores, encrypted provenance chain,
///         encrypted valuation per brand tier, and confidential counterfeit risk scores.
contract PrivateSecondhandLuxuryAuthentication is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Brand { HERMES, CHANEL, LOUIS_VUITTON, ROLEX, PATEK_PHILIPPE, FERRARI }
    enum ItemCategory { BAG, WATCH, JEWELRY, CLOTHING, SHOES, VEHICLE }

    struct LuxuryItem {
        string itemId;         // Reference code
        Brand brand;
        ItemCategory category;
        address currentOwner;
        euint64 authenticityScore;    // encrypted authenticity 0-1000
        euint64 conditionScore;       // encrypted condition grade 0-100
        euint64 currentValueUSD;      // encrypted current market value
        euint64 counterfeitsRisk;     // encrypted counterfeit risk 0-1000
        euint64 provenanceChainLength;// encrypted # of verified transfers
        uint256 manufacturingYear;
        bool authenticated;
        bool listed;
    }

    struct ProvenanceRecord {
        uint256 itemId;
        address previousOwner;
        address newOwner;
        euint64 transferPriceUSD;   // encrypted transaction price
        euint64 authenticatorScore; // encrypted re-authentication at transfer
        uint256 transferDate;
        bool verified;
    }

    struct AuthenticatorProfile {
        euint64 expertiseScore;      // encrypted expertise 0-1000
        euint64 accuracyRate;        // encrypted accuracy of past auths (bps)
        euint64 totalAuthentications;// encrypted count
        bool certified;
    }

    mapping(uint256 => LuxuryItem) private items;
    mapping(uint256 => ProvenanceRecord[]) private provenance;
    mapping(address => AuthenticatorProfile) private authenticators;
    uint256 public itemCount;
    euint64 private _totalMarketValue;
    mapping(address => bool) public isCertifiedAuthenticator;

    event ItemRegistered(uint256 indexed id, string itemId, Brand brand);
    event Authenticated(uint256 indexed itemId, address authenticator);
    event ProvenanceRecorded(uint256 indexed itemId, address from, address to);
    event ItemListed(uint256 indexed itemId);
    event CounterfeitAlert(uint256 indexed itemId);

    constructor() Ownable(msg.sender) {
        _totalMarketValue = FHE.asEuint64(0);
        FHE.allowThis(_totalMarketValue);
        isCertifiedAuthenticator[msg.sender] = true;
    }

    function certifyAuthenticator(address auth) external onlyOwner {
        isCertifiedAuthenticator[auth] = true;
        authenticators[auth] = AuthenticatorProfile({
            expertiseScore: FHE.asEuint64(500),
            accuracyRate: FHE.asEuint64(9000),
            totalAuthentications: FHE.asEuint64(0),
            certified: true
        });
        FHE.allowThis(authenticators[auth].expertiseScore);
        FHE.allowThis(authenticators[auth].accuracyRate);
        FHE.allowThis(authenticators[auth].totalAuthentications);
    }

    function registerItem(
        string calldata itemId, Brand brand, ItemCategory category,
        externalEuint64 encValue, bytes calldata vProof,
        uint256 mfgYear
    ) external returns (uint256 id) {
        euint64 value = FHE.fromExternal(encValue, vProof);
        id = itemCount++;
        items[id] = LuxuryItem({
            itemId: itemId, brand: brand, category: category,
            currentOwner: msg.sender, authenticityScore: FHE.asEuint64(0),
            conditionScore: FHE.asEuint64(0), currentValueUSD: value,
            counterfeitsRisk: FHE.asEuint64(500), provenanceChainLength: FHE.asEuint64(0),
            manufacturingYear: mfgYear, authenticated: false, listed: false
        });
        FHE.allowThis(items[id].authenticityScore);
        FHE.allowThis(items[id].conditionScore);
        FHE.allowThis(items[id].currentValueUSD);
        FHE.allowThis(items[id].counterfeitsRisk);
        FHE.allowThis(items[id].provenanceChainLength);
        FHE.allow(items[id].currentValueUSD, msg.sender);
        emit ItemRegistered(id, itemId, brand);
    }

    function authenticateItem(
        uint256 itemId,
        externalEuint64 encAuthScore, bytes calldata aProof,
        externalEuint64 encCondition, bytes calldata cProof,
        externalEuint64 encCounterfeit, bytes calldata cfProof,
        externalEuint64 encValue, bytes calldata vProof
    ) external {
        require(isCertifiedAuthenticator[msg.sender], "Not certified");
        LuxuryItem storage item = items[itemId];
        euint64 authScore = FHE.fromExternal(encAuthScore, aProof);
        euint64 condition = FHE.fromExternal(encCondition, cProof);
        euint64 counterfeit = FHE.fromExternal(encCounterfeit, cfProof);
        euint64 value = FHE.fromExternal(encValue, vProof);
        item.authenticityScore = authScore;
        item.conditionScore = condition;
        item.counterfeitsRisk = counterfeit;
        _totalMarketValue = FHE.sub(_totalMarketValue, item.currentValueUSD);
        item.currentValueUSD = value;
        _totalMarketValue = FHE.add(_totalMarketValue, value);
        item.authenticated = true;
        // Check for counterfeit alert
        ebool highRisk = FHE.ge(counterfeit, FHE.asEuint64(700));
        FHE.allowThis(item.authenticityScore);
        FHE.allowThis(item.conditionScore);
        FHE.allowThis(item.counterfeitsRisk);
        FHE.allowThis(item.currentValueUSD);
        FHE.allow(item.authenticityScore, item.currentOwner);
        FHE.allow(item.currentValueUSD, item.currentOwner);
        FHE.allowThis(_totalMarketValue);
        // Update authenticator stats
        AuthenticatorProfile storage ap = authenticators[msg.sender];
        ap.totalAuthentications = FHE.add(ap.totalAuthentications, FHE.asEuint64(1));
        FHE.allowThis(ap.totalAuthentications);
        emit Authenticated(itemId, msg.sender);
    }

    function transferWithProvenance(
        uint256 itemId, address newOwner,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint64 encReAuthScore, bytes calldata rProof
    ) external nonReentrant {
        LuxuryItem storage item = items[itemId];
        require(item.currentOwner == msg.sender && item.authenticated, "Not owner or unauthenticated");
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint64 reAuth = FHE.fromExternal(encReAuthScore, rProof);
        provenance[itemId].push(ProvenanceRecord({
            itemId: itemId, previousOwner: msg.sender, newOwner: newOwner,
            transferPriceUSD: price, authenticatorScore: reAuth,
            transferDate: block.timestamp, verified: true
        }));
        uint256 idx = provenance[itemId].length - 1;
        FHE.allowThis(provenance[itemId][idx].transferPriceUSD);
        FHE.allow(provenance[itemId][idx].transferPriceUSD, msg.sender);
        FHE.allow(provenance[itemId][idx].transferPriceUSD, newOwner);
        FHE.allowThis(provenance[itemId][idx].authenticatorScore);
        item.currentOwner = newOwner;
        item.provenanceChainLength = FHE.add(item.provenanceChainLength, FHE.asEuint64(1));
        item.listed = false;
        FHE.allowThis(item.provenanceChainLength);
        FHE.allow(item.currentValueUSD, newOwner);
        emit ProvenanceRecorded(itemId, msg.sender, newOwner);
    }

    function listForSale(uint256 itemId) external {
        require(items[itemId].currentOwner == msg.sender, "Not owner");
        require(items[itemId].authenticated, "Not authenticated");
        items[itemId].listed = true;
        emit ItemListed(itemId);
    }
}
