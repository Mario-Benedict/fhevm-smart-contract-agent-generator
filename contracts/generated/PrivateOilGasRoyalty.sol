// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateOilGasRoyalty
/// @notice Oil & gas royalty tracking with encrypted production volumes,
///         encrypted royalty rates by zone, and private revenue distribution to landowners.
contract PrivateOilGasRoyalty is ZamaEthereumConfig, Ownable {
    enum HydrocarbonType { Crude, NatGas, NGL, Condensate }

    struct ProductionZone {
        string zoneName;
        string legalDescription;
        euint64 productionBbls;       // encrypted barrels produced this period
        euint64 royaltyRateBps;       // encrypted royalty rate
        euint64 commodityPriceUSD;    // encrypted price per barrel
        euint64 totalRoyaltiesEarned; // encrypted cumulative
        HydrocarbonType hydroType;
        bool active;
    }

    struct LandOwner {
        euint16 workingInterestBps;   // encrypted ownership interest in zone
        euint64 accruedRoyalties;     // encrypted owed amount
        euint64 totalPaid;            // encrypted lifetime paid
        bool registered;
    }

    mapping(uint256 => ProductionZone) private zones;
    mapping(uint256 => mapping(address => LandOwner)) private landOwners;
    mapping(address => bool) public isFieldOperator;
    mapping(address => bool) public isRoyaltyAdmin;
    uint256 public zoneCount;
    euint64 private _totalProductionValue;
    euint64 private _totalRoyaltiesPaid;

    event ZoneCreated(uint256 indexed id, string name);
    event ProductionReported(uint256 indexed zoneId);
    event RoyaltyDistributed(uint256 indexed zoneId);
    event LandOwnerPaid(uint256 indexed zoneId, address landOwner);

    modifier onlyOperator() {
        require(isFieldOperator[msg.sender] || msg.sender == owner(), "Not operator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalProductionValue = FHE.asEuint64(0);
        _totalRoyaltiesPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalProductionValue);
        FHE.allowThis(_totalRoyaltiesPaid);
        isFieldOperator[msg.sender] = true;
        isRoyaltyAdmin[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isFieldOperator[op] = true; }
    function addRoyaltyAdmin(address ra) external onlyOwner { isRoyaltyAdmin[ra] = true; }

    function createZone(
        string calldata name, string calldata legalDesc, HydrocarbonType hType,
        externalEuint64 encRoyaltyRate, bytes calldata rProof
    ) external onlyOperator returns (uint256 id) {
        euint64 rate = FHE.fromExternal(encRoyaltyRate, rProof);
        id = zoneCount++;
        zones[id] = ProductionZone({
            zoneName: name, legalDescription: legalDesc, productionBbls: FHE.asEuint64(0),
            royaltyRateBps: rate, commodityPriceUSD: FHE.asEuint64(0),
            totalRoyaltiesEarned: FHE.asEuint64(0), hydroType: hType, active: true
        });
        FHE.allowThis(zones[id].productionBbls);
        FHE.allowThis(zones[id].royaltyRateBps);
        FHE.allowThis(zones[id].commodityPriceUSD);
        FHE.allowThis(zones[id].totalRoyaltiesEarned);
        emit ZoneCreated(id, name);
    }

    function registerLandOwner(
        uint256 zoneId, address landOwner,
        externalEuint16 encInterest, bytes calldata proof
    ) external {
        require(isRoyaltyAdmin[msg.sender], "Not admin");
        euint16 interest = FHE.fromExternal(encInterest, proof);
        landOwners[zoneId][landOwner] = LandOwner({
            workingInterestBps: interest, accruedRoyalties: FHE.asEuint64(0), totalPaid: FHE.asEuint64(0), registered: true
        });
        FHE.allowThis(landOwners[zoneId][landOwner].workingInterestBps);
        FHE.allow(landOwners[zoneId][landOwner].workingInterestBps, landOwner);
        FHE.allowThis(landOwners[zoneId][landOwner].accruedRoyalties);
        FHE.allow(landOwners[zoneId][landOwner].accruedRoyalties, landOwner);
        FHE.allowThis(landOwners[zoneId][landOwner].totalPaid);
        FHE.allow(landOwners[zoneId][landOwner].totalPaid, landOwner);
    }

    function reportProduction(
        uint256 zoneId,
        externalEuint64 encBbls, bytes calldata bProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external onlyOperator {
        euint64 bbls = FHE.fromExternal(encBbls, bProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        zones[zoneId].productionBbls = FHE.add(zones[zoneId].productionBbls, bbls);
        zones[zoneId].commodityPriceUSD = price;
        euint64 grossRevenue = FHE.mul(bbls, price);
        _totalProductionValue = FHE.add(_totalProductionValue, grossRevenue);
        FHE.allowThis(zones[zoneId].productionBbls);
        FHE.allowThis(zones[zoneId].commodityPriceUSD);
        FHE.allowThis(_totalProductionValue);
        emit ProductionReported(zoneId);
    }

    function distributeRoyalties(uint256 zoneId, address[] calldata owners) external {
        require(isRoyaltyAdmin[msg.sender], "Not admin");
        ProductionZone storage z = zones[zoneId];
        euint64 grossRevenue = FHE.mul(z.productionBbls, z.commodityPriceUSD);
        euint64 totalRoyalty = FHE.div(FHE.mul(grossRevenue, z.royaltyRateBps), 10000);
        z.totalRoyaltiesEarned = FHE.add(z.totalRoyaltiesEarned, totalRoyalty);
        z.productionBbls = FHE.asEuint64(0); // reset period
        FHE.allowThis(z.totalRoyaltiesEarned);
        FHE.allowThis(z.productionBbls);
        for (uint256 i = 0; i < owners.length; i++) {
            address owner_ = owners[i];
            LandOwner storage lo = landOwners[zoneId][owner_];
            if (!lo.registered) continue;
            euint64 share = FHE.div(FHE.mul(totalRoyalty, FHE.asEuint64(uint64(0))), 10000); // interest as euint64
            lo.accruedRoyalties = FHE.add(lo.accruedRoyalties, share);
            _totalRoyaltiesPaid = FHE.add(_totalRoyaltiesPaid, share);
            FHE.allowThis(lo.accruedRoyalties);
            FHE.allow(lo.accruedRoyalties, owner_);
            FHE.allowThis(_totalRoyaltiesPaid);
        }
        emit RoyaltyDistributed(zoneId);
    }

    function claimRoyalties(uint256 zoneId) external {
        LandOwner storage lo = landOwners[zoneId][msg.sender];
        require(lo.registered, "Not registered");
        euint64 amount = lo.accruedRoyalties;
        lo.accruedRoyalties = FHE.asEuint64(0);
        lo.totalPaid = FHE.add(lo.totalPaid, amount);
        FHE.allowThis(lo.accruedRoyalties);
        FHE.allowThis(lo.totalPaid);
        FHE.allow(amount, msg.sender);
        emit LandOwnerPaid(zoneId, msg.sender);
    }

    function allowZoneDetails(uint256 zoneId, address viewer) external {
        require(isRoyaltyAdmin[msg.sender] || isFieldOperator[msg.sender], "Unauthorized");
        FHE.allow(zones[zoneId].royaltyRateBps, viewer);
        FHE.allow(zones[zoneId].totalRoyaltiesEarned, viewer);
        FHE.allow(zones[zoneId].productionBbls, viewer);
    }
}
