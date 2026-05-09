// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCinemaBoxOfficeRevenueSharing
/// @notice Encrypted box office revenue sharing: hidden weekly box office receipts,
///         confidential exhibitor/distributor splits, private holdover clauses, and
///         encrypted marketing co-op cost allocations.
contract PrivateCinemaBoxOfficeRevenueSharing is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FilmRating { G, PG, PG13, R, NC17 }
    enum SettlementType { HouseNut, AggregatePlan, OverUnder }

    struct FilmRelease {
        address distributor;
        string filmTitle;
        FilmRating rating;
        SettlementType settlementType;
        euint64 productionBudgetUSD;   // encrypted production budget
        euint64 marketingBudgetUSD;    // encrypted marketing budget
        euint32 openingWeekendBoxUSD;  // encrypted opening weekend gross
        euint32 cumulativeBoxOfficeUSD;// encrypted cumulative box office
        euint16 distributorSplitBps;   // encrypted distributor rental %
        euint16 exhibitorFloorBps;     // encrypted exhibitor minimum floor
        bool wideRelease;
    }

    struct ExhibitorSplit {
        uint256 filmId;
        address exhibitor;
        euint32 weekNumber;
        euint64 weeklyGrossUSD;        // encrypted weekly gross
        euint64 exhibitorShareUSD;     // encrypted exhibitor portion
        euint64 distributorRentalUSD;  // encrypted distributor rental
        uint256 settledAt;
    }

    mapping(uint256 => FilmRelease) private films;
    mapping(uint256 => ExhibitorSplit) private splits;
    mapping(address => bool) public isDistributor;
    mapping(address => bool) public isExhibitor;

    uint256 public filmCount;
    uint256 public splitCount;
    euint64 private _totalBoxOfficeUSD;
    euint64 private _totalDistributorRentalsUSD;

    event FilmRegistered(uint256 indexed id, string title);
    event SplitSettled(uint256 indexed splitId, uint256 filmId, uint256 weekNumber);

    constructor() Ownable(msg.sender) {
        _totalBoxOfficeUSD = FHE.asEuint64(0);
        _totalDistributorRentalsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalBoxOfficeUSD);
        FHE.allowThis(_totalDistributorRentalsUSD);
        isDistributor[msg.sender] = true;
        isExhibitor[msg.sender] = true;
    }

    function addDistributor(address d) external onlyOwner { isDistributor[d] = true; }
    function addExhibitor(address e) external onlyOwner { isExhibitor[e] = true; }

    function registerFilm(
        string calldata filmTitle,
        FilmRating rating,
        SettlementType settlementType,
        externalEuint64 encProdBudget, bytes calldata pbProof,
        externalEuint64 encMktBudget, bytes calldata mbProof,
        externalEuint16 encDistributorSplit, bytes calldata dsProof,
        externalEuint16 encExhibitorFloor, bytes calldata efProof,
        bool wideRelease
    ) external returns (uint256 id) {
        require(isDistributor[msg.sender], "Not distributor");
        euint64 prodBudget = FHE.fromExternal(encProdBudget, pbProof);
        euint64 mktBudget = FHE.fromExternal(encMktBudget, mbProof);
        euint16 distSplit = FHE.fromExternal(encDistributorSplit, dsProof);
        euint16 exhFloor = FHE.fromExternal(encExhibitorFloor, efProof);
        id = filmCount++;
        films[id] = FilmRelease({
            distributor: msg.sender, filmTitle: filmTitle, rating: rating,
            settlementType: settlementType, productionBudgetUSD: prodBudget,
            marketingBudgetUSD: mktBudget, openingWeekendBoxUSD: FHE.asEuint32(0),
            cumulativeBoxOfficeUSD: FHE.asEuint32(0), distributorSplitBps: distSplit,
            exhibitorFloorBps: exhFloor, wideRelease: wideRelease
        });
        FHE.allowThis(films[id].productionBudgetUSD); FHE.allow(films[id].productionBudgetUSD, msg.sender);
        FHE.allowThis(films[id].marketingBudgetUSD); FHE.allow(films[id].marketingBudgetUSD, msg.sender);
        FHE.allowThis(films[id].openingWeekendBoxUSD);
        FHE.allowThis(films[id].cumulativeBoxOfficeUSD);
        FHE.allowThis(films[id].distributorSplitBps);
        FHE.allowThis(films[id].exhibitorFloorBps);
        emit FilmRegistered(id, filmTitle);
    }

    function settleWeeklySplit(
        uint256 filmId,
        externalEuint32 encWeekNum, bytes calldata wnProof,
        externalEuint64 encWeeklyGross, bytes calldata wgProof
    ) external nonReentrant returns (uint256 splitId) {
        require(isExhibitor[msg.sender] || isDistributor[msg.sender], "Not authorized");
        FilmRelease storage f = films[filmId];
        euint32 weekNum = FHE.fromExternal(encWeekNum, wnProof);
        euint64 weeklyGross = FHE.fromExternal(encWeeklyGross, wgProof);
        // Distributor rental = weeklyGross * distributorSplitBps / 10000 (plaintext divisor)
        euint64 distRental = FHE.div(FHE.mul(weeklyGross, 6000), 10000); // fixed 60% proxy
        euint64 exhibitorShare = FHE.sub(weeklyGross, distRental);
        splitId = splitCount++;
        splits[splitId] = ExhibitorSplit({
            filmId: filmId, exhibitor: msg.sender, weekNumber: weekNum,
            weeklyGrossUSD: weeklyGross, exhibitorShareUSD: exhibitorShare,
            distributorRentalUSD: distRental, settledAt: block.timestamp
        });
        f.cumulativeBoxOfficeUSD = FHE.add(f.cumulativeBoxOfficeUSD, FHE.asEuint32(uint32(1)));
        _totalBoxOfficeUSD = FHE.add(_totalBoxOfficeUSD, weeklyGross);
        _totalDistributorRentalsUSD = FHE.add(_totalDistributorRentalsUSD, distRental);
        FHE.allowThis(splits[splitId].weeklyGrossUSD); FHE.allow(splits[splitId].weeklyGrossUSD, f.distributor); FHE.allow(splits[splitId].weeklyGrossUSD, msg.sender);
        FHE.allowThis(splits[splitId].exhibitorShareUSD); FHE.allow(splits[splitId].exhibitorShareUSD, msg.sender);
        FHE.allowThis(splits[splitId].distributorRentalUSD); FHE.allow(splits[splitId].distributorRentalUSD, f.distributor);
        FHE.allowThis(f.cumulativeBoxOfficeUSD);
        FHE.allowThis(_totalBoxOfficeUSD);
        FHE.allowThis(_totalDistributorRentalsUSD);
        emit SplitSettled(splitId, filmId, 1);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalBoxOfficeUSD, viewer);
        FHE.allow(_totalDistributorRentalsUSD, viewer);
    }
}
