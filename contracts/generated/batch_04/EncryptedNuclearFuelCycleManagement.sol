// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedNuclearFuelCycleManagement
/// @notice Nuclear fuel management with encrypted enrichment levels, burn-up data,
///         fuel costs, and IAEA safeguards compliance scores.
contract EncryptedNuclearFuelCycleManagement is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FuelStatus { FRESH, IN_REACTOR, COOLING, REPROCESSING, DISPOSAL }
    enum ReactorType { PWR, BWR, PHWR, RBMK, SMR }

    struct FuelAssembly {
        string assemblyId;
        ReactorType reactorType;
        euint8  enrichmentPct;         // encrypted U-235 %
        euint64 burnupMWdPerTU;        // encrypted burn-up level
        euint64 acquisitionCostUSD;    // encrypted cost
        euint64 disposalCostReserveUSD;// encrypted provision
        euint8  safeguardsScore;       // encrypted IAEA compliance 0-100
        euint32 massKgHeavyMetal;      // encrypted kg HM
        uint256 loadDate;
        FuelStatus status;
    }

    struct ReactorUnit {
        string reactorName;
        string country;
        ReactorType reactorType;
        euint64 thermalPowerMWt;       // encrypted thermal output
        euint64 electricPowerMWe;      // encrypted net electric output
        euint64 capacityFactorBps;     // encrypted utilization %
        euint64 fuelCostPerMWhUSD;     // encrypted fuel cost
        euint32 assemblyCount;         // encrypted number of assemblies
        bool operational;
    }

    mapping(uint256 => FuelAssembly) private assemblies;
    mapping(uint256 => ReactorUnit) private reactors;
    mapping(address => bool) public isNuclearOperator;
    mapping(address => bool) public isIAEAInspector;
    uint256 public assemblyCount;
    uint256 public reactorCount;
    euint64 private _totalFuelInvestmentUSD;
    euint64 private _totalDisposalReserveUSD;

    event ReactorRegistered(uint256 indexed reactorId, string name);
    event AssemblyLoaded(uint256 indexed assemblyId, uint256 reactorId);
    event SafeguardsUpdated(uint256 indexed assemblyId);
    event DisposalReserveUpdated();

    constructor() Ownable(msg.sender) {
        _totalFuelInvestmentUSD = FHE.asEuint64(0);
        _totalDisposalReserveUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalFuelInvestmentUSD);
        FHE.allowThis(_totalDisposalReserveUSD);
        isNuclearOperator[msg.sender] = true;
        isIAEAInspector[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isNuclearOperator[op] = true; }
    function addInspector(address ins) external onlyOwner { isIAEAInspector[ins] = true; }

    function registerReactor(
        string calldata name, string calldata country, ReactorType rType,
        externalEuint64 encThermal,  bytes calldata thProof,
        externalEuint64 encElectric, bytes calldata elProof,
        externalEuint64 encCapFactor,bytes calldata cfProof
    ) external returns (uint256 reactorId) {
        require(isNuclearOperator[msg.sender], "Not operator");
        euint64 thermal  = FHE.fromExternal(encThermal, thProof);
        euint64 electric = FHE.fromExternal(encElectric, elProof);
        euint64 capFactor= FHE.fromExternal(encCapFactor, cfProof);
        reactorId = reactorCount++;
        reactors[reactorId].reactorName = name;
        reactors[reactorId].country = country;
        reactors[reactorId].reactorType = rType;
        reactors[reactorId].thermalPowerMWt = thermal;
        reactors[reactorId].electricPowerMWe = electric;
        reactors[reactorId].capacityFactorBps = capFactor;
        reactors[reactorId].fuelCostPerMWhUSD = FHE.asEuint64(0);
        reactors[reactorId].assemblyCount = FHE.asEuint32(0);
        reactors[reactorId].operational = true;
        FHE.allowThis(reactors[reactorId].thermalPowerMWt);
        FHE.allowThis(reactors[reactorId].electricPowerMWe);
        FHE.allowThis(reactors[reactorId].capacityFactorBps);
        FHE.allowThis(reactors[reactorId].fuelCostPerMWhUSD);
        FHE.allowThis(reactors[reactorId].assemblyCount);
        emit ReactorRegistered(reactorId, name);
    }

    function loadFuelAssembly(
        string calldata assemblyId,
        uint256 reactorId,
        externalEuint8  encEnrichment,  bytes calldata enProof,
        externalEuint64 encCost,        bytes calldata cProof,
        externalEuint64 encDisposal,    bytes calldata dProof,
        externalEuint8  encSafeguards,  bytes calldata sgProof,
        externalEuint32 encMassKg,      bytes calldata mProof
    ) external returns (uint256 asmId) {
        require(isNuclearOperator[msg.sender], "Not operator");
        euint8  enrichment = FHE.fromExternal(encEnrichment, enProof);
        euint64 cost       = FHE.fromExternal(encCost, cProof);
        euint64 disposal   = FHE.fromExternal(encDisposal, dProof);
        euint8  safeguards = FHE.fromExternal(encSafeguards, sgProof);
        euint32 massKg     = FHE.fromExternal(encMassKg, mProof);
        asmId = assemblyCount++;
        assemblies[asmId].assemblyId = assemblyId;
        assemblies[asmId].reactorType = reactors[reactorId].reactorType;
        assemblies[asmId].enrichmentPct = enrichment;
        assemblies[asmId].burnupMWdPerTU = FHE.asEuint64(0);
        assemblies[asmId].acquisitionCostUSD = cost;
        assemblies[asmId].disposalCostReserveUSD = disposal;
        assemblies[asmId].safeguardsScore = safeguards;
        assemblies[asmId].massKgHeavyMetal = massKg;
        assemblies[asmId].loadDate = block.timestamp;
        assemblies[asmId].status = FuelStatus.IN_REACTOR;
        reactors[reactorId].assemblyCount = FHE.add(reactors[reactorId].assemblyCount, FHE.asEuint32(1));
        _totalFuelInvestmentUSD = FHE.add(_totalFuelInvestmentUSD, cost);
        _totalDisposalReserveUSD = FHE.add(_totalDisposalReserveUSD, disposal);
        FHE.allowThis(assemblies[asmId].enrichmentPct);
        FHE.allowThis(assemblies[asmId].burnupMWdPerTU);
        FHE.allowThis(assemblies[asmId].acquisitionCostUSD);
        FHE.allow(assemblies[asmId].acquisitionCostUSD, msg.sender);
        FHE.allowThis(assemblies[asmId].disposalCostReserveUSD);
        FHE.allowThis(assemblies[asmId].safeguardsScore);
        FHE.allowThis(assemblies[asmId].massKgHeavyMetal);
        FHE.allowThis(reactors[reactorId].assemblyCount);
        FHE.allowThis(_totalFuelInvestmentUSD);
        FHE.allowThis(_totalDisposalReserveUSD);
        emit AssemblyLoaded(asmId, reactorId);
    }

    function updateSafeguardsScore(
        uint256 asmId,
        externalEuint8  encScore,   bytes calldata proof,
        externalEuint64 encBurnup,  bytes calldata burnProof
    ) external {
        require(isIAEAInspector[msg.sender], "Not IAEA inspector");
        assemblies[asmId].safeguardsScore = FHE.fromExternal(encScore, proof);
        assemblies[asmId].burnupMWdPerTU = FHE.fromExternal(encBurnup, burnProof);
        FHE.allowThis(assemblies[asmId].safeguardsScore);
        FHE.allowThis(assemblies[asmId].burnupMWdPerTU);
        emit SafeguardsUpdated(asmId);
    }

    function allowFuelView(address viewer) external onlyOwner {
        FHE.allow(_totalFuelInvestmentUSD, viewer);
        FHE.allow(_totalDisposalReserveUSD, viewer);
    }
}
