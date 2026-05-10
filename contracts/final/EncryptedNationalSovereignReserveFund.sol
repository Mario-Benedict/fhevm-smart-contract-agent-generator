// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedNationalSovereignReserveFund
/// @notice Encrypted sovereign reserve fund: hidden asset allocations per class,
///         private geopolitical risk scores, confidential coverage ratios,
///         and encrypted strategic diversification metrics.
contract EncryptedNationalSovereignReserveFund is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SovereignAssetClass { PublicEquity, SovereignBonds, Infrastructure, PrivateEquity, RealEstate, GoldReserves, ForeignExchange }

    struct ReserveAllocation {
        SovereignAssetClass assetClass;
        string allocationRef;
        string jurisdiction;
        euint64 allocatedValueUSD;
        euint64 targetValueUSD;
        euint16 geopoliticalRiskScore;
        euint16 liquidityScore;
        bool active;
    }

    struct StrategicReserveTarget {
        string reserveRef;
        euint64 reserveLevelUSD;
        euint64 targetLevelUSD;
        euint16 coverageMonths;
    }

    mapping(uint256 => ReserveAllocation) private allocations;
    mapping(uint256 => StrategicReserveTarget) private reserves;
    mapping(address => bool) public isFundManager;

    uint256 public allocationCount;
    uint256 public reserveCount;
    euint64 private _totalFundAUMUSD;
    euint64 private _totalTargetAUMUSD;
    euint64 private _totalReturnGeneratedUSD;

    event AllocationCreated(uint256 indexed id, SovereignAssetClass assetClass);
    event AllocationRebalanced(uint256 indexed id);
    event StrategicReserveSet(uint256 indexed id);

    modifier onlyFundManager() {
        require(isFundManager[msg.sender] || msg.sender == owner(), "Not fund manager");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalFundAUMUSD = FHE.asEuint64(0);
        _totalTargetAUMUSD = FHE.asEuint64(0);
        _totalReturnGeneratedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalFundAUMUSD);
        FHE.allowThis(_totalTargetAUMUSD);
        FHE.allowThis(_totalReturnGeneratedUSD);
        isFundManager[msg.sender] = true;
    }

    function addFundManager(address fm) external onlyOwner { isFundManager[fm] = true; }

    function createAllocation(
        SovereignAssetClass assetClass, string calldata allocationRef, string calldata jurisdiction,
        externalEuint64 encAllocated, bytes calldata alProof,
        externalEuint64 encTarget, bytes calldata tProof,
        externalEuint16 encGeoRisk, bytes calldata grProof,
        externalEuint16 encLiquidity, bytes calldata lqProof
    ) external onlyFundManager returns (uint256 id) {
        euint64 allocated = FHE.fromExternal(encAllocated, alProof);
        euint64 target    = FHE.fromExternal(encTarget, tProof);
        euint16 geoRisk   = FHE.fromExternal(encGeoRisk, grProof);
        euint16 liquidity = FHE.fromExternal(encLiquidity, lqProof);
        id = allocationCount++;
        allocations[id] = ReserveAllocation({
            assetClass: assetClass, allocationRef: allocationRef, jurisdiction: jurisdiction,
            allocatedValueUSD: allocated, targetValueUSD: target,
            geopoliticalRiskScore: geoRisk, liquidityScore: liquidity, active: true
        });
        _totalFundAUMUSD = FHE.add(_totalFundAUMUSD, allocated);
        _totalTargetAUMUSD = FHE.add(_totalTargetAUMUSD, target);
        FHE.allowThis(allocations[id].allocatedValueUSD); FHE.allow(allocations[id].allocatedValueUSD, msg.sender) // [acl_misconfig]
        FHE.allow(_totalFundAUMUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalTargetAUMUSD, msg.sender); // [acl_misconfig]
        FHE.allowThis(allocations[id].targetValueUSD); FHE.allow(allocations[id].targetValueUSD, msg.sender);
        FHE.allowThis(allocations[id].geopoliticalRiskScore);
        FHE.allowThis(allocations[id].liquidityScore);
        FHE.allowThis(_totalFundAUMUSD); FHE.allowThis(_totalTargetAUMUSD);
        emit AllocationCreated(id, assetClass);
    }

    function rebalanceAllocation(uint256 allocationId, externalEuint64 encNewValue, bytes calldata proof) external onlyFundManager {
        ReserveAllocation storage a = allocations[allocationId];
        euint64 newValue = FHE.fromExternal(encNewValue, proof);
        _totalFundAUMUSD = FHE.sub(_totalFundAUMUSD, a.allocatedValueUSD);
        _totalFundAUMUSD = FHE.add(_totalFundAUMUSD, newValue);
        euint64 returnGenerated = FHE.sub(newValue, a.allocatedValueUSD);
        _totalReturnGeneratedUSD = FHE.add(_totalReturnGeneratedUSD, returnGenerated);
        a.allocatedValueUSD = newValue;
        FHE.allowThis(a.allocatedValueUSD); FHE.allow(a.allocatedValueUSD, msg.sender);
        FHE.allowThis(_totalFundAUMUSD); FHE.allowThis(_totalReturnGeneratedUSD);
        emit AllocationRebalanced(allocationId);
    }

    function setStrategicReserve(
        string calldata reserveRef,
        externalEuint64 encLevel, bytes calldata lProof,
        externalEuint64 encTarget, bytes calldata tProof,
        externalEuint16 encCoverage, bytes calldata cProof
    ) external onlyFundManager returns (uint256 id) {
        euint64 level    = FHE.fromExternal(encLevel, lProof);
        euint64 target   = FHE.fromExternal(encTarget, tProof);
        euint16 coverage = FHE.fromExternal(encCoverage, cProof);
        id = reserveCount++;
        reserves[id] = StrategicReserveTarget({ reserveRef: reserveRef, reserveLevelUSD: level, targetLevelUSD: target, coverageMonths: coverage });
        FHE.allowThis(reserves[id].reserveLevelUSD); FHE.allow(reserves[id].reserveLevelUSD, msg.sender);
        FHE.allowThis(reserves[id].targetLevelUSD); FHE.allow(reserves[id].targetLevelUSD, msg.sender);
        FHE.allowThis(reserves[id].coverageMonths);
        emit StrategicReserveSet(id);
    }

    function allowFundStats(address viewer) external onlyOwner {
        FHE.allow(_totalFundAUMUSD, viewer); FHE.allow(_totalTargetAUMUSD, viewer); FHE.allow(_totalReturnGeneratedUSD, viewer);
    }
}
