// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSportsTransferMarket - Sealed negotiation platform for athlete transfer fees
contract EncryptedSportsTransferMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct AthleteContract {
        address currentClub;
        string  athleteId;
        euint64 marketValue;
        euint64 buyoutClause;
        euint64 weeklyWage;
        uint256 contractExpiry;
        bool    listedForTransfer;
    }

    struct TransferOffer {
        uint256 athleteId;
        address offeringClub;
        euint64 offerAmount;
        euint64 proposedWage;
        euint8  contractYears;
        bool    accepted;
        bool    rejected;
        uint256 expiresAt;
    }

    mapping(uint256 => AthleteContract) public athletes;
    mapping(uint256 => TransferOffer)   public offers;
    mapping(address => bool) public registeredClubs;
    uint256 public athleteCount;
    uint256 public offerCount;

    event AthleteRegistered(uint256 indexed athleteId, address club);
    event ListedForTransfer(uint256 indexed athleteId);
    event OfferMade(uint256 indexed offerId, uint256 indexed athleteId);
    event OfferAccepted(uint256 indexed offerId);
    event OfferRejected(uint256 indexed offerId);

    constructor() Ownable(msg.sender) {}

    function registerClub(address club) external onlyOwner { registeredClubs[club] = true; }

    function registerAthlete(
        string calldata athleteId,
        uint256 contractExpiryDays,
        externalEuint64 encValue,   bytes calldata valueProof,
        externalEuint64 encBuyout,  bytes calldata buyoutProof,
        externalEuint64 encWage,    bytes calldata wageProof
    ) external returns (uint256 id) {
        require(registeredClubs[msg.sender], "Not registered club");
        id = athleteCount++;
        AthleteContract storage a = athletes[id];
        a.currentClub    = msg.sender;
        a.athleteId      = athleteId;
        a.marketValue    = FHE.fromExternal(encValue,  valueProof);
        a.buyoutClause   = FHE.fromExternal(encBuyout, buyoutProof);
        a.weeklyWage     = FHE.fromExternal(encWage,   wageProof);
        a.contractExpiry = block.timestamp + contractExpiryDays * 1 days;
        FHE.allowThis(a.marketValue); FHE.allowThis(a.buyoutClause); FHE.allowThis(a.weeklyWage);
        FHE.allow(a.marketValue, msg.sender); FHE.allow(a.buyoutClause, msg.sender);
        emit AthleteRegistered(id, msg.sender);
    }

    function listForTransfer(uint256 athleteId) external {
        AthleteContract storage a = athletes[athleteId];
        require(a.currentClub == msg.sender, "Not owning club");
        a.listedForTransfer = true;
        FHE.allow(a.marketValue, address(this));
        emit ListedForTransfer(athleteId);
    }

    function makeOffer(
        uint256 athleteId,
        uint256 validDays,
        externalEuint64 encOffer, bytes calldata offerProof,
        externalEuint64 encWage,  bytes calldata wageProof,
        externalEuint8 encYears, bytes calldata yearsProof
    ) external returns (uint256 offerId) {
        require(registeredClubs[msg.sender], "Not club");
        AthleteContract storage a = athletes[athleteId];
        require(a.listedForTransfer, "Not listed");
        require(a.currentClub != msg.sender, "Own athlete");
        offerId = offerCount++;
        TransferOffer storage o = offers[offerId];
        o.athleteId    = athleteId;
        o.offeringClub = msg.sender;
        o.offerAmount  = FHE.fromExternal(encOffer, offerProof);
        o.proposedWage = FHE.fromExternal(encWage,  wageProof);
        o.contractYears = FHE.fromExternal(encYears, yearsProof);
        o.expiresAt    = block.timestamp + validDays * 1 days;
        FHE.allowThis(o.offerAmount); FHE.allowThis(o.proposedWage); FHE.allowThis(o.contractYears);
        FHE.allow(o.offerAmount, a.currentClub);
        FHE.allow(o.proposedWage, a.currentClub);
        emit OfferMade(offerId, athleteId);
    }

    function acceptOffer(uint256 offerId) external nonReentrant {
        TransferOffer storage o = offers[offerId];
        AthleteContract storage a = athletes[o.athleteId];
        require(a.currentClub == msg.sender, "Not owning club");
        require(!o.accepted && !o.rejected, "Already decided");
        require(block.timestamp <= o.expiresAt, "Expired");
        o.accepted = true;
        a.currentClub = o.offeringClub;
        a.listedForTransfer = false;
        FHE.allowTransient(o.offerAmount, msg.sender); // receive fee
        emit OfferAccepted(offerId);
    }

    function rejectOffer(uint256 offerId) external {
        TransferOffer storage o = offers[offerId];
        require(athletes[o.athleteId].currentClub == msg.sender, "Not owning club");
        require(!o.accepted && !o.rejected, "Already decided");
        o.rejected = true;
        emit OfferRejected(offerId);
    }
}
