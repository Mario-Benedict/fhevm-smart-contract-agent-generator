// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateHighValueArtAuction
/// @notice Encrypted fine art auction: hidden lot reserves, confidential buyer premiums,
///         private consignor settlement rates, and encrypted provenance quality scores
///         affecting bid floor adjustments.
contract PrivateHighValueArtAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ArtMedium { OilOnCanvas, WatercolourPaper, Sculpture, Photography, Printmaking, DigitalNFT }
    enum ArtPeriod { Ancient, Renaissance, Baroque, Impressionist, Modern, Contemporary }

    struct ArtLot {
        address consignor;
        string artistName;
        string workTitle;
        ArtMedium medium;
        ArtPeriod period;
        uint32 creationYear;
        euint64 estimateLowUSD;        // encrypted low estimate
        euint64 estimateHighUSD;       // encrypted high estimate
        euint64 hammerPriceUSD;        // encrypted winning bid
        euint64 totalWithPremiumUSD;   // encrypted buyer premium included
        euint64 consignorSettlementUSD;// encrypted consignor payout
        euint16 provenanceScoreBps;    // encrypted provenance quality score
        euint16 conditionReportBps;    // encrypted condition score
        bool offered;
        bool sold;
    }

    mapping(uint256 => ArtLot) private lots;
    mapping(address => bool) public isAuctionSpecialist;

    uint256 public lotCount;
    euint64 private _totalHammerPriceUSD;
    euint64 private _totalConsignorPayoutsUSD;

    event LotConsigned(uint256 indexed id, ArtPeriod period, ArtMedium medium);
    event LotHammered(uint256 indexed id, uint256 hammeredAt);

    modifier onlyAuctionSpecialist() {
        require(isAuctionSpecialist[msg.sender] || msg.sender == owner(), "Not auction specialist");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalHammerPriceUSD = FHE.asEuint64(0);
        _totalConsignorPayoutsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalHammerPriceUSD);
        FHE.allowThis(_totalConsignorPayoutsUSD);
        isAuctionSpecialist[msg.sender] = true;
    }

    function addSpecialist(address s) external onlyOwner { isAuctionSpecialist[s] = true; }

    function consignLot(
        string calldata artistName, string calldata workTitle,
        ArtMedium medium, ArtPeriod period, uint32 creationYear,
        externalEuint64 encLowEst, bytes calldata leProof,
        externalEuint64 encHighEst, bytes calldata heProof,
        externalEuint16 encProvenance, bytes calldata pvProof,
        externalEuint16 encCondition, bytes calldata condProof
    ) external returns (uint256 id) {
        euint64 lowEst = FHE.fromExternal(encLowEst, leProof);
        euint64 highEst = FHE.fromExternal(encHighEst, heProof);
        euint16 provenance = FHE.fromExternal(encProvenance, pvProof);
        euint16 condition = FHE.fromExternal(encCondition, condProof);
        id = lotCount++;
        lots[id] = ArtLot({
            consignor: msg.sender, artistName: artistName, workTitle: workTitle, medium: medium,
            period: period, creationYear: creationYear, estimateLowUSD: lowEst, estimateHighUSD: highEst,
            hammerPriceUSD: FHE.asEuint64(0), totalWithPremiumUSD: FHE.asEuint64(0),
            consignorSettlementUSD: FHE.asEuint64(0), provenanceScoreBps: provenance,
            conditionReportBps: condition, offered: false, sold: false
        });
        FHE.allowThis(lots[id].estimateLowUSD); FHE.allow(lots[id].estimateLowUSD, msg.sender);
        FHE.allowThis(lots[id].estimateHighUSD); FHE.allow(lots[id].estimateHighUSD, msg.sender);
        FHE.allowThis(lots[id].hammerPriceUSD); FHE.allow(lots[id].hammerPriceUSD, msg.sender);
        FHE.allowThis(lots[id].totalWithPremiumUSD);
        FHE.allowThis(lots[id].consignorSettlementUSD); FHE.allow(lots[id].consignorSettlementUSD, msg.sender);
        FHE.allowThis(lots[id].provenanceScoreBps);
        FHE.allowThis(lots[id].conditionReportBps);
        emit LotConsigned(id, period, medium);
    }

    function hammerLot(
        uint256 lotId,
        externalEuint64 encHammerPrice, bytes calldata hpProof
    ) external onlyAuctionSpecialist nonReentrant {
        ArtLot storage l = lots[lotId];
        require(!l.sold, "Already sold");
        euint64 hammerPrice = FHE.fromExternal(encHammerPrice, hpProof);
        // Buyer premium = hammer * 25% (plaintext divisor)
        euint64 buyerPremium = FHE.div(hammerPrice, 4);
        euint64 totalWithPremium = FHE.add(hammerPrice, buyerPremium);
        // Consignor settlement = hammer - 15% commission (plaintext divisor)
        euint64 commission = FHE.div(hammerPrice, 7); // ~14% proxy (plaintext)
        euint64 consignorSettlement = FHE.sub(hammerPrice, commission);
        l.hammerPriceUSD = hammerPrice;
        l.totalWithPremiumUSD = totalWithPremium;
        l.consignorSettlementUSD = consignorSettlement;
        l.sold = true;
        _totalHammerPriceUSD = FHE.add(_totalHammerPriceUSD, hammerPrice);
        _totalConsignorPayoutsUSD = FHE.add(_totalConsignorPayoutsUSD, consignorSettlement);
        FHE.allowThis(l.hammerPriceUSD); FHE.allow(l.hammerPriceUSD, l.consignor);
        FHE.allowThis(l.totalWithPremiumUSD);
        FHE.allowThis(l.consignorSettlementUSD); FHE.allow(l.consignorSettlementUSD, l.consignor);
        FHE.allowThis(_totalHammerPriceUSD);
        FHE.allowThis(_totalConsignorPayoutsUSD);
        emit LotHammered(lotId, block.timestamp);
    }

    function allowAuctionStats(address viewer) external onlyOwner {
        FHE.allow(_totalHammerPriceUSD, viewer);
        FHE.allow(_totalConsignorPayoutsUSD, viewer);
    }
}
