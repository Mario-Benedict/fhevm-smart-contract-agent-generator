// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedBiogasPlantEnergyCertificate
/// @notice Biogas plant operators mint encrypted renewable energy certificates (RECs).
///         Encrypted energy output, encrypted methane content, and verified sustainability scores.
contract EncryptedBiogasPlantEnergyCertificate is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum FeedstockType { FoodWaste, AnimalManure, AgricultureResidue, MunicipalWaste, IndustrialWaste }
    enum RECStatus { Minted, Listed, Sold, Retired, Cancelled }

    struct BiogasPlant {
        address operator;
        string plantId;
        string country;
        FeedstockType feedstock;
        euint32 installedCapacityKW;    // encrypted plant capacity
        euint32 sustainabilityScore;    // encrypted sustainability rating
        euint64 totalRECsMinted;        // encrypted RECs produced
        bool certified;
    }

    struct REC {
        uint256 plantId;
        euint64 energyMWh;              // encrypted energy in MWh
        euint16 methaneCH4Percent;      // encrypted methane content %
        euint64 pricePerMWhCents;       // encrypted market price
        euint64 proceedsCents;          // encrypted sale proceeds
        uint256 generationYear;
        RECStatus status;
        address currentHolder;
    }

    mapping(uint256 => BiogasPlant) private plants;
    mapping(uint256 => REC) private recs;
    mapping(address => bool) public isVerifier;
    mapping(address => bool) public isBuyer;

    uint256 public plantCount;
    uint256 public recCount;
    euint64 private _totalEnergyMWh;
    euint64 private _totalRetiredMWh;
    euint64 private _totalMarketValueCents;

    event PlantRegistered(uint256 indexed id, string plantId, FeedstockType feedstock);
    event RECMinted(uint256 indexed id, uint256 plantId);
    event RECListed(uint256 indexed id);
    event RECSold(uint256 indexed id, address buyer);
    event RECRetired(uint256 indexed id);

    modifier onlyVerifier() {
        require(isVerifier[msg.sender] || msg.sender == owner(), "Not verifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalEnergyMWh = FHE.asEuint64(0);
        _totalRetiredMWh = FHE.asEuint64(0);
        _totalMarketValueCents = FHE.asEuint64(0);
        FHE.allowThis(_totalEnergyMWh);
        FHE.allowThis(_totalRetiredMWh);
        FHE.allowThis(_totalMarketValueCents);
        isVerifier[msg.sender] = true;
    }

    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }
    function addBuyer(address b) external onlyOwner { isBuyer[b] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerPlant(
        string calldata plantId,
        string calldata country,
        FeedstockType feedstock,
        externalEuint32 encCapacity, bytes calldata cProof,
        externalEuint32 encScore, bytes calldata sProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 capacity = FHE.fromExternal(encCapacity, cProof);
        euint32 score = FHE.fromExternal(encScore, sProof);
        id = plantCount++;
        plants[id] = BiogasPlant({
            operator: msg.sender, plantId: plantId, country: country, feedstock: feedstock,
            installedCapacityKW: capacity, sustainabilityScore: score,
            totalRECsMinted: FHE.asEuint64(0), certified: false
        });
        FHE.allowThis(plants[id].installedCapacityKW);
        FHE.allow(plants[id].installedCapacityKW, msg.sender);
        FHE.allowThis(plants[id].sustainabilityScore);
        FHE.allow(plants[id].sustainabilityScore, msg.sender);
        FHE.allowThis(plants[id].totalRECsMinted);
        emit PlantRegistered(id, plantId, feedstock);
    }

    function certifyPlant(uint256 plantId) external onlyVerifier { plants[plantId].certified = true; }

    function mintREC(
        uint256 plantId,
        externalEuint64 encEnergy, bytes calldata eProof,
        externalEuint16 encMethane, bytes calldata mProof,
        uint256 generationYear
    ) external whenNotPaused returns (uint256 id) {
        require(plants[plantId].operator == msg.sender && plants[plantId].certified, "Not certified operator");
        euint64 energy = FHE.fromExternal(encEnergy, eProof);
        euint16 methane = FHE.fromExternal(encMethane, mProof);
        id = recCount++;
        recs[id] = REC({
            plantId: plantId, energyMWh: energy, methaneCH4Percent: methane,
            pricePerMWhCents: FHE.asEuint64(0), proceedsCents: FHE.asEuint64(0),
            generationYear: generationYear, status: RECStatus.Minted,
            currentHolder: msg.sender
        });
        plants[plantId].totalRECsMinted = FHE.add(plants[plantId].totalRECsMinted, energy);
        _totalEnergyMWh = FHE.add(_totalEnergyMWh, energy);
        FHE.allowThis(recs[id].energyMWh);
        FHE.allow(recs[id].energyMWh, msg.sender);
        FHE.allowThis(recs[id].methaneCH4Percent);
        FHE.allow(recs[id].methaneCH4Percent, msg.sender);
        FHE.allowThis(recs[id].pricePerMWhCents);
        FHE.allowThis(recs[id].proceedsCents);
        FHE.allowThis(plants[plantId].totalRECsMinted);
        FHE.allowThis(_totalEnergyMWh);
        emit RECMinted(id, plantId);
    }

    function listREC(uint256 recId, externalEuint64 encPrice, bytes calldata proof) external {
        REC storage r = recs[recId];
        require(r.currentHolder == msg.sender && r.status == RECStatus.Minted, "Not holder or wrong status");
        r.pricePerMWhCents = FHE.fromExternal(encPrice, proof);
        r.status = RECStatus.Listed;
        FHE.allowThis(r.pricePerMWhCents);
        emit RECListed(recId);
    }

    function purchaseREC(uint256 recId) external nonReentrant whenNotPaused {
        require(isBuyer[msg.sender], "Not buyer");
        REC storage r = recs[recId];
        require(r.status == RECStatus.Listed, "Not listed");
        euint64 proceeds = FHE.mul(r.energyMWh, r.pricePerMWhCents);
        r.proceedsCents = proceeds;
        address prevHolder = r.currentHolder;
        r.currentHolder = msg.sender;
        r.status = RECStatus.Sold;
        _totalMarketValueCents = FHE.add(_totalMarketValueCents, proceeds);
        FHE.allowThis(r.proceedsCents);
        FHE.allow(r.proceedsCents, prevHolder);
        FHE.allow(r.proceedsCents, msg.sender);
        FHE.allow(r.energyMWh, msg.sender);
        FHE.allowThis(_totalMarketValueCents);
        emit RECSold(recId, msg.sender);
    }

    function retireREC(uint256 recId) external {
        REC storage r = recs[recId];
        require(r.currentHolder == msg.sender, "Not holder");
        r.status = RECStatus.Retired;
        _totalRetiredMWh = FHE.add(_totalRetiredMWh, r.energyMWh);
        FHE.allowThis(_totalRetiredMWh);
        emit RECRetired(recId);
    }

    function allowEnergyStats(address viewer) external onlyOwner {
        FHE.allow(_totalEnergyMWh, viewer);
        FHE.allow(_totalRetiredMWh, viewer);
        FHE.allow(_totalMarketValueCents, viewer);
    }
}
