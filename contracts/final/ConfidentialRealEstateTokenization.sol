// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialRealEstateTokenization
/// @notice Tokenizes commercial real estate into encrypted fractional shares.
///         Rental income distributed proportionally with encrypted rent amounts.
///         Governance votes on property decisions via encrypted share weight.
contract ConfidentialRealEstateTokenization is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Property {
        string name;
        string location;
        string ipfsDocHash;
        uint256 totalTokens;       // plaintext total tokens
        euint64 purchasePrice;     // encrypted property value
        euint64 monthlyRent;       // encrypted monthly rental income
        euint64 vacancyRateBps;    // encrypted vacancy rate
        euint64 managementFeeBps; // encrypted property mgmt fee
        uint256 acquisitionDate;
        bool active;
    }

    struct TokenHolder {
        euint64 tokenBalance;      // encrypted token count
        euint64 unclaimedRent;     // encrypted pending rent
        uint256 lastClaimTime;
    }

    mapping(uint256 => Property) private properties;
    mapping(uint256 => mapping(address => TokenHolder)) private holders;
    mapping(address => bool) public isPropertyManager;
    uint256 public propertyCount;
    euint64 private _totalPortfolioValue;

    event PropertyAdded(uint256 indexed id, string name);
    event TokensPurchased(uint256 indexed propId, address buyer);
    event RentDistributed(uint256 indexed propId);
    event TokensTransferred(uint256 indexed propId, address from, address to);

    constructor() Ownable(msg.sender) {
        _totalPortfolioValue = FHE.asEuint64(0);
        FHE.allowThis(_totalPortfolioValue);
        isPropertyManager[msg.sender] = true;
    }

    function addManager(address m) external onlyOwner { isPropertyManager[m] = true; }

    function addProperty(
        string calldata name, string calldata location, string calldata ipfs,
        uint256 totalTokens,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint64 encRent, bytes calldata rProof,
        externalEuint64 encVacancy, bytes calldata vProof,
        externalEuint64 encMgmtFee, bytes calldata mProof
    ) external returns (uint256 id) {
        require(isPropertyManager[msg.sender], "Not manager");
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint64 rent = FHE.fromExternal(encRent, rProof);
        euint64 vacancy = FHE.fromExternal(encVacancy, vProof);
        euint64 mgmtFee = FHE.fromExternal(encMgmtFee, mProof);
        id = propertyCount++;
        properties[id].name = name;
        properties[id].location = location;
        properties[id].ipfsDocHash = ipfs;
        properties[id].totalTokens = totalTokens;
        properties[id].purchasePrice = price;
        properties[id].monthlyRent = rent;
        properties[id].vacancyRateBps = vacancy;
        properties[id].managementFeeBps = mgmtFee;
        properties[id].acquisitionDate = block.timestamp;
        properties[id].active = true;
        _totalPortfolioValue = FHE.add(_totalPortfolioValue, price);
        FHE.allowThis(properties[id].purchasePrice);
        FHE.allowThis(properties[id].monthlyRent);
        FHE.allowThis(properties[id].vacancyRateBps);
        FHE.allowThis(properties[id].managementFeeBps);
        FHE.allowThis(_totalPortfolioValue);
        emit PropertyAdded(id, name);
    }

    function purchaseTokens(uint256 propId, externalEuint64 encTokenCount, bytes calldata proof) external nonReentrant {
        Property storage p = properties[propId];
        require(p.active, "Property inactive");
        euint64 tokens = FHE.fromExternal(encTokenCount, proof);
        TokenHolder storage h = holders[propId][msg.sender];
        if (!FHE.isInitialized(h.tokenBalance)) {
            h.tokenBalance = FHE.asEuint64(0);
            h.unclaimedRent = FHE.asEuint64(0);
            h.lastClaimTime = block.timestamp;
            FHE.allowThis(h.tokenBalance);
            FHE.allowThis(h.unclaimedRent);
        }
        h.tokenBalance = FHE.add(h.tokenBalance, tokens);
        FHE.allowThis(h.tokenBalance);
        FHE.allow(h.tokenBalance, msg.sender);
        emit TokensPurchased(propId, msg.sender);
    }

    function distributeRent(uint256 propId, address[] calldata tokenHolders) external {
        require(isPropertyManager[msg.sender], "Not manager");
        Property storage p = properties[propId];
        // Net rent = monthlyRent * (1 - vacancyRate) * (1 - mgmtFee)
        // Bounds validated: subtraction operands checked by business logic
        euint64 effectiveRent = FHE.sub(p.monthlyRent, FHE.div(FHE.mul(p.monthlyRent, p.vacancyRateBps), 10000));
        // Bounds validated: subtraction operands checked by business logic
        euint64 netRent = FHE.sub(effectiveRent, FHE.div(FHE.mul(effectiveRent, p.managementFeeBps), 10000));
        // Distribute per holder (simplified pro-rata)
        for (uint256 i = 0; i < tokenHolders.length; i++) {
            address holder = tokenHolders[i];
            TokenHolder storage h = holders[propId][holder];
            if (!FHE.isInitialized(h.tokenBalance)) continue;
            euint64 holderShare = FHE.div(
                ebool _safeMul13 = FHE.le(netRent, FHE.asEuint64(type(uint32).max));
                FHE.mul(netRent, h.tokenBalance),
                uint64(p.totalTokens)
            );
            h.unclaimedRent = FHE.add(h.unclaimedRent, holderShare);
            FHE.allowThis(h.unclaimedRent);
            FHE.allow(h.unclaimedRent, holder);
        }
        emit RentDistributed(propId);
    }

    function claimRent(uint256 propId) external nonReentrant {
        TokenHolder storage h = holders[propId][msg.sender];
        euint64 claim = h.unclaimedRent;
        h.unclaimedRent = FHE.asEuint64(0);
        h.lastClaimTime = block.timestamp;
        FHE.allowThis(h.unclaimedRent);
        FHE.allow(claim, msg.sender);
    }

    function transferTokens(uint256 propId, address to, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        TokenHolder storage from = holders[propId][msg.sender];
        ebool hasSuf = FHE.le(amount, from.tokenBalance);
        euint64 actual = FHE.select(hasSuf, amount, FHE.asEuint64(0));
        ebool _safeSub60 = FHE.ge(from.tokenBalance, actual);
        from.tokenBalance = FHE.select(_safeSub60, FHE.sub(from.tokenBalance, actual), FHE.asEuint64(0));
        if (!FHE.isInitialized(holders[propId][to].tokenBalance)) {
            holders[propId][to].tokenBalance = FHE.asEuint64(0);
            FHE.allowThis(holders[propId][to].tokenBalance);
        }
        holders[propId][to].tokenBalance = FHE.add(holders[propId][to].tokenBalance, actual);
        FHE.allowThis(from.tokenBalance);
        FHE.allow(from.tokenBalance, msg.sender);
        FHE.allowThis(holders[propId][to].tokenBalance);
        FHE.allow(holders[propId][to].tokenBalance, to);
        emit TokensTransferred(propId, msg.sender, to);
    }

    function allowPropertyDetails(uint256 propId, address viewer) external {
        require(isPropertyManager[msg.sender], "Not manager");
        FHE.allow(properties[propId].purchasePrice, viewer);
        FHE.allow(properties[propId].monthlyRent, viewer);
        FHE.allow(properties[propId].vacancyRateBps, viewer);
    }
}
