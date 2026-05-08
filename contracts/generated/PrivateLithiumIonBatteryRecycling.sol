// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateLithiumIonBatteryRecycling
/// @notice Encrypted EV battery recycling: hidden material recovery rates per batch,
///         confidential recycler payments for recovered lithium/cobalt, private
///         environmental compliance scores, and encrypted carbon credit allocation
///         for recycling operations.
contract PrivateLithiumIonBatteryRecycling is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum BatteryChemistry { NMC, LFP, NCA, LCO, LNMO }
    enum RecyclingProcess { Hydromet, Pyrometallurgy, DirectRecycling, MechanicalShredding }

    struct RecyclingBatch {
        address recycler;
        address batteryProvider;
        BatteryChemistry chemistry;
        RecyclingProcess process;
        euint32 batteryWeightKg;        // encrypted input weight
        euint32 lithiumRecoveredKg;     // encrypted lithium recovered
        euint32 cobaltRecoveredKg;      // encrypted cobalt recovered
        euint32 nickelRecoveredKg;      // encrypted nickel recovered
        euint64 recoveryValueUSD;       // encrypted total recovery value
        euint64 processingCostUSD;      // encrypted processing cost
        euint16 complianceScoreBps;     // encrypted regulatory compliance
        euint64 carbonCreditsEarned;    // encrypted carbon credits
        uint256 processedAt;
    }

    mapping(uint256 => RecyclingBatch) private batches;
    mapping(address => bool) public isEnvironmentalRegulator;
    mapping(address => bool) public isAccreditedRecycler;

    uint256 public batchCount;
    euint64 private _totalRecoveryValueUSD;
    euint64 private _totalCarbonCreditsIssued;
    euint32 private _totalLithiumRecoveredKg;

    event BatchProcessed(uint256 indexed id, BatteryChemistry chemistry, RecyclingProcess process);
    event CarbonCreditsIssued(uint256 indexed batchId, uint256 issuedAt);

    modifier onlyEnvRegulator() {
        require(isEnvironmentalRegulator[msg.sender] || msg.sender == owner(), "Not env regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRecoveryValueUSD = FHE.asEuint64(0);
        _totalCarbonCreditsIssued = FHE.asEuint64(0);
        _totalLithiumRecoveredKg = FHE.asEuint32(0);
        FHE.allowThis(_totalRecoveryValueUSD);
        FHE.allowThis(_totalCarbonCreditsIssued);
        FHE.allowThis(_totalLithiumRecoveredKg);
        isEnvironmentalRegulator[msg.sender] = true;
        isAccreditedRecycler[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function accreditRecycler(address r) external onlyOwner { isAccreditedRecycler[r] = true; }
    function addRegulator(address r) external onlyOwner { isEnvironmentalRegulator[r] = true; }

    function processBatch(
        address batteryProvider,
        BatteryChemistry chemistry,
        RecyclingProcess process,
        externalEuint32 encWeight, bytes calldata wProof,
        externalEuint32 encLithium, bytes calldata liProof,
        externalEuint32 encCobalt, bytes calldata coProof,
        externalEuint32 encNickel, bytes calldata niProof,
        externalEuint64 encRecoveryValue, bytes calldata rvProof,
        externalEuint64 encCost, bytes calldata costProof
    ) external whenNotPaused returns (uint256 id) {
        require(isAccreditedRecycler[msg.sender], "Not accredited recycler");
        euint32 weight = FHE.fromExternal(encWeight, wProof);
        euint32 lithium = FHE.fromExternal(encLithium, liProof);
        euint32 cobalt = FHE.fromExternal(encCobalt, coProof);
        euint32 nickel = FHE.fromExternal(encNickel, niProof);
        euint64 recoveryVal = FHE.fromExternal(encRecoveryValue, rvProof);
        euint64 cost = FHE.fromExternal(encCost, costProof);
        id = batchCount++;
        batches[id] = RecyclingBatch({
            recycler: msg.sender, batteryProvider: batteryProvider, chemistry: chemistry, process: process,
            batteryWeightKg: weight, lithiumRecoveredKg: lithium, cobaltRecoveredKg: cobalt,
            nickelRecoveredKg: nickel, recoveryValueUSD: recoveryVal, processingCostUSD: cost,
            complianceScoreBps: FHE.asEuint16(0), carbonCreditsEarned: FHE.asEuint64(0),
            processedAt: block.timestamp
        });
        _totalRecoveryValueUSD = FHE.add(_totalRecoveryValueUSD, recoveryVal);
        _totalLithiumRecoveredKg = FHE.add(_totalLithiumRecoveredKg, lithium);
        FHE.allowThis(batches[id].batteryWeightKg); FHE.allow(batches[id].batteryWeightKg, msg.sender);
        FHE.allowThis(batches[id].lithiumRecoveredKg); FHE.allow(batches[id].lithiumRecoveredKg, msg.sender); FHE.allow(batches[id].lithiumRecoveredKg, batteryProvider);
        FHE.allowThis(batches[id].cobaltRecoveredKg); FHE.allow(batches[id].cobaltRecoveredKg, msg.sender);
        FHE.allowThis(batches[id].nickelRecoveredKg); FHE.allow(batches[id].nickelRecoveredKg, msg.sender);
        FHE.allowThis(batches[id].recoveryValueUSD); FHE.allow(batches[id].recoveryValueUSD, msg.sender); FHE.allow(batches[id].recoveryValueUSD, batteryProvider);
        FHE.allowThis(batches[id].processingCostUSD); FHE.allow(batches[id].processingCostUSD, msg.sender);
        FHE.allowThis(batches[id].complianceScoreBps);
        FHE.allowThis(batches[id].carbonCreditsEarned);
        FHE.allowThis(_totalRecoveryValueUSD);
        FHE.allowThis(_totalLithiumRecoveredKg);
        emit BatchProcessed(id, chemistry, process);
    }

    function certifyAndIssueCarbonCredits(
        uint256 batchId,
        externalEuint16 encCompliance, bytes calldata compProof,
        externalEuint64 encCredits, bytes calldata credProof
    ) external onlyEnvRegulator {
        RecyclingBatch storage b = batches[batchId];
        b.complianceScoreBps = FHE.fromExternal(encCompliance, compProof);
        b.carbonCreditsEarned = FHE.fromExternal(encCredits, credProof);
        _totalCarbonCreditsIssued = FHE.add(_totalCarbonCreditsIssued, b.carbonCreditsEarned);
        FHE.allowThis(b.complianceScoreBps); FHE.allow(b.complianceScoreBps, b.recycler);
        FHE.allowThis(b.carbonCreditsEarned); FHE.allow(b.carbonCreditsEarned, b.recycler);
        FHE.allowThis(_totalCarbonCreditsIssued);
        emit CarbonCreditsIssued(batchId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalRecoveryValueUSD, viewer);
        FHE.allow(_totalCarbonCreditsIssued, viewer);
        FHE.allow(_totalLithiumRecoveredKg, viewer);
    }
}
