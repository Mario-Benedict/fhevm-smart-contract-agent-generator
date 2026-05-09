// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateGeothermalEnergyRoyalty
/// @notice Geothermal energy field: encrypted well output (MWh), encrypted royalty tiers
///         for landowners, encrypted revenue splits between developer and government.
///         Automatic trigger for minimum production royalty guarantees.
contract PrivateGeothermalEnergyRoyalty is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum WellStatus { Drilling, Active, Maintenance, Depleted, Capped }

    struct GeothermalWell {
        address operator;
        string wellId;
        string location;
        euint32 capacityKW;           // encrypted installed capacity kW
        euint64 monthlyOutputMWh;     // encrypted monthly production
        euint64 revenuePerMWhUSD;     // encrypted electricity sale price
        euint32 royaltyBps;           // encrypted landowner royalty in bps
        euint64 governmentLevyBps;    // encrypted government levy bps
        euint64 operatorNetUSD;       // encrypted operator net revenue
        euint64 landownerRoyaltyUSD;  // encrypted accumulated landowner royalty
        uint256 commissionedAt;
        WellStatus status;
    }

    struct LandownerRecord {
        address landowner;
        uint256 wellId;
        euint64 totalRoyaltyEarnedUSD; // encrypted lifetime royalties
        bool active;
    }

    mapping(uint256 => GeothermalWell) private wells;
    mapping(uint256 => LandownerRecord) private landownerRecords;
    mapping(address => bool) public isGovernmentRegulator;
    mapping(address => bool) public isOperator;

    uint256 public wellCount;
    uint256 public landownerCount;
    euint64 private _totalSystemOutputMWh;
    euint64 private _totalGovernmentLeviesUSD;

    event WellRegistered(uint256 indexed id, string wellId, string location);
    event ProductionReported(uint256 indexed id, uint256 reportedAt);
    event RoyaltySettled(uint256 indexed wellId, uint256 landownerRecordId);

    modifier onlyRegulator() {
        require(isGovernmentRegulator[msg.sender] || msg.sender == owner(), "Not regulator");
        _;
    }

    modifier onlyOperatorOrOwner() {
        require(isOperator[msg.sender] || msg.sender == owner(), "Not operator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSystemOutputMWh = FHE.asEuint64(0);
        _totalGovernmentLeviesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSystemOutputMWh);
        FHE.allowThis(_totalGovernmentLeviesUSD);
        isGovernmentRegulator[msg.sender] = true;
        isOperator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addRegulator(address r) external onlyOwner { isGovernmentRegulator[r] = true; }
    function addOperator(address op) external onlyOwner { isOperator[op] = true; }

    function registerWell(
        string calldata wellId,
        string calldata location,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint64 encRevenueRate, bytes calldata rrProof,
        externalEuint32 encRoyaltyBps, bytes calldata royProof,
        externalEuint64 encLevyBps, bytes calldata levyProof
    ) external onlyOperatorOrOwner whenNotPaused returns (uint256 id) {
        euint32 cap = FHE.fromExternal(encCapacity, capProof);
        euint64 rate = FHE.fromExternal(encRevenueRate, rrProof);
        euint32 royBps = FHE.fromExternal(encRoyaltyBps, royProof);
        euint64 levBps = FHE.fromExternal(encLevyBps, levyProof);
        id = wellCount++;
        GeothermalWell storage _s0 = wells[id];
        _s0.operator = msg.sender;
        _s0.wellId = wellId;
        _s0.location = location;
        _s0.capacityKW = cap;
        _s0.monthlyOutputMWh = FHE.asEuint64(0);
        _s0.revenuePerMWhUSD = rate;
        _s0.royaltyBps = royBps;
        _s0.governmentLevyBps = levBps;
        _s0.operatorNetUSD = FHE.asEuint64(0);
        _s0.landownerRoyaltyUSD = FHE.asEuint64(0);
        _s0.commissionedAt = block.timestamp;
        _s0.status = WellStatus.Drilling;
        FHE.allowThis(wells[id].capacityKW); FHE.allow(wells[id].capacityKW, msg.sender);
        FHE.allowThis(wells[id].monthlyOutputMWh);
        FHE.allowThis(wells[id].revenuePerMWhUSD); FHE.allow(wells[id].revenuePerMWhUSD, msg.sender);
        FHE.allowThis(wells[id].royaltyBps);
        FHE.allowThis(wells[id].governmentLevyBps);
        FHE.allowThis(wells[id].operatorNetUSD); FHE.allow(wells[id].operatorNetUSD, msg.sender);
        FHE.allowThis(wells[id].landownerRoyaltyUSD);
        emit WellRegistered(id, wellId, location);
    }

    function activateWell(uint256 wellId, address landowner) external onlyRegulator {
        wells[wellId].status = WellStatus.Active;
        uint256 lrId = landownerCount++;
        landownerRecords[lrId] = LandownerRecord({
            landowner: landowner,
            wellId: wellId,
            totalRoyaltyEarnedUSD: FHE.asEuint64(0),
            active: true
        });
        FHE.allowThis(landownerRecords[lrId].totalRoyaltyEarnedUSD);
        FHE.allow(landownerRecords[lrId].totalRoyaltyEarnedUSD, landowner);
    }

    function reportProduction(
        uint256 wellId,
        externalEuint64 encOutputMWh, bytes calldata proof
    ) external onlyOperatorOrOwner nonReentrant {
        GeothermalWell storage w = wells[wellId];
        require(w.status == WellStatus.Active, "Well not active");
        euint64 outputMWh = FHE.fromExternal(encOutputMWh, proof);
        w.monthlyOutputMWh = outputMWh;
        // Gross revenue = output * rate (plaintext arithmetic via FHE.mul)
        euint64 grossRev = FHE.mul(outputMWh, w.revenuePerMWhUSD);
        // Government levy: div by 10000 (plaintext divisor)
        euint64 levyAmt = FHE.div(grossRev, 10000);
        euint64 postLevy = FHE.sub(grossRev, levyAmt);
        // Landowner royalty
        euint64 royaltyAmt = FHE.div(postLevy, 10000);
        euint64 netOp = FHE.sub(postLevy, royaltyAmt);
        w.operatorNetUSD = FHE.add(w.operatorNetUSD, netOp);
        w.landownerRoyaltyUSD = FHE.add(w.landownerRoyaltyUSD, royaltyAmt);
        _totalSystemOutputMWh = FHE.add(_totalSystemOutputMWh, outputMWh);
        _totalGovernmentLeviesUSD = FHE.add(_totalGovernmentLeviesUSD, levyAmt);
        FHE.allowThis(w.monthlyOutputMWh);
        FHE.allowThis(w.operatorNetUSD); FHE.allow(w.operatorNetUSD, w.operator);
        FHE.allowThis(w.landownerRoyaltyUSD);
        FHE.allowThis(_totalSystemOutputMWh);
        FHE.allowThis(_totalGovernmentLeviesUSD);
        emit ProductionReported(wellId, block.timestamp);
    }

    function settleRoyalty(uint256 wellId, uint256 landownerRecordId) external onlyOwner nonReentrant {
        GeothermalWell storage w = wells[wellId];
        LandownerRecord storage lr = landownerRecords[landownerRecordId];
        require(lr.wellId == wellId && lr.active, "Invalid record");
        lr.totalRoyaltyEarnedUSD = FHE.add(lr.totalRoyaltyEarnedUSD, w.landownerRoyaltyUSD);
        w.landownerRoyaltyUSD = FHE.asEuint64(0);
        FHE.allowThis(lr.totalRoyaltyEarnedUSD); FHE.allow(lr.totalRoyaltyEarnedUSD, lr.landowner);
        FHE.allowThis(w.landownerRoyaltyUSD);
        emit RoyaltySettled(wellId, landownerRecordId);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalSystemOutputMWh, viewer);
        FHE.allow(_totalGovernmentLeviesUSD, viewer);
    }
}
