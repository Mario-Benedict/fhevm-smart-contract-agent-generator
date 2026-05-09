// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateMilitaryProcurementContract
/// @notice Defense procurement: encrypted contract values, encrypted capability scores,
///         and classified performance metrics for weapons system tenders.
contract PrivateMilitaryProcurementContract is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum WeaponSystemCategory { Avionics, ArmorVehicle, NavalVessel, CyberDefense, Logistics, Surveillance }
    enum SecurityClearance { Unclassified, Confidential, Secret, TopSecret }
    enum ContractStatus { RFP, BidEvaluation, Awarded, InProduction, Delivered, Cancelled }

    struct DefenseContract {
        address primeContractor;
        WeaponSystemCategory category;
        string programName;
        string systemDesignator;
        SecurityClearance classification;
        euint64 contractValueUSD;         // encrypted contract value
        euint64 researchCostUSD;          // encrypted R&D budget
        euint64 productionCostPerUnit;    // encrypted unit cost
        euint32 unitQuantity;             // encrypted quantity ordered
        euint32 performanceScore;         // encrypted test performance
        euint32 reliabilityRatingBps;     // encrypted reliability
        uint256 deliveryDeadline;
        ContractStatus status;
    }

    struct SubcontractorBid {
        uint256 contractId;
        address subcontractor;
        string systemComponent;
        euint64 bidValueUSD;              // encrypted sub-bid amount
        euint32 capabilityScore;          // encrypted capability rating
        SecurityClearance clearanceLevel;
        bool awarded;
    }

    mapping(uint256 => DefenseContract) private contracts;
    mapping(uint256 => SubcontractorBid[]) private subBids;
    mapping(address => SecurityClearance) public contractorClearance;
    mapping(address => bool) public isProcurementOfficer;

    uint256 public contractCount;
    euint64 private _totalDefenseBudget;
    euint64 private _totalContracted;

    event ContractIssued(uint256 indexed id, WeaponSystemCategory cat, string program);
    event SubBidSubmitted(uint256 indexed contractId, address sub, string component);
    event ContractAwarded(uint256 indexed id, address contractor);
    event DeliveryConfirmed(uint256 indexed id);

    modifier onlyOfficer() {
        require(isProcurementOfficer[msg.sender] || msg.sender == owner(), "Not procurement officer");
        _;
    }

    modifier onlyClearance(SecurityClearance required) {
        require(uint8(contractorClearance[msg.sender]) >= uint8(required), "Insufficient clearance");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDefenseBudget = FHE.asEuint64(0);
        _totalContracted = FHE.asEuint64(0);
        FHE.allowThis(_totalDefenseBudget);
        FHE.allowThis(_totalContracted);
        isProcurementOfficer[msg.sender] = true;
        contractorClearance[msg.sender] = SecurityClearance.TopSecret;
    }

    function grantClearance(address c, SecurityClearance level) external onlyOwner {
        contractorClearance[c] = level;
    }
    function addOfficer(address o) external onlyOwner { isProcurementOfficer[o] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function issueContract(
        address primeContractor,
        WeaponSystemCategory category,
        string calldata programName,
        string calldata designator,
        SecurityClearance classification,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint64 encRD, bytes calldata rdProof,
        externalEuint64 encUnitCost, bytes calldata ucProof,
        externalEuint32 encQty, bytes calldata qProof,
        uint256 deliveryDays
    ) external onlyOfficer whenNotPaused returns (uint256 id) {
        euint64 val = FHE.fromExternal(encValue, vProof);
        euint64 rd = FHE.fromExternal(encRD, rdProof);
        euint64 unitCost = FHE.fromExternal(encUnitCost, ucProof);
        euint32 qty = FHE.fromExternal(encQty, qProof);
        id = contractCount++;
        DefenseContract storage _s0 = contracts[id];
        _s0.primeContractor = primeContractor;
        _s0.category = category;
        _s0.programName = programName;
        _s0.systemDesignator = designator;
        _s0.classification = classification;
        _s0.contractValueUSD = val;
        _s0.researchCostUSD = rd;
        _s0.productionCostPerUnit = unitCost;
        _s0.unitQuantity = qty;
        _s0.performanceScore = FHE.asEuint32(0);
        _s0.reliabilityRatingBps = FHE.asEuint32(0);
        _s0.deliveryDeadline = block.timestamp + deliveryDays * 1 days;
        _s0.status = ContractStatus.Awarded;
        _totalContracted = FHE.add(_totalContracted, val);
        FHE.allowThis(contracts[id].contractValueUSD);
        FHE.allow(contracts[id].contractValueUSD, primeContractor);
        FHE.allowThis(contracts[id].researchCostUSD);
        FHE.allow(contracts[id].researchCostUSD, primeContractor);
        FHE.allowThis(contracts[id].productionCostPerUnit);
        FHE.allow(contracts[id].productionCostPerUnit, primeContractor);
        FHE.allowThis(contracts[id].unitQuantity);
        FHE.allow(contracts[id].unitQuantity, primeContractor);
        FHE.allowThis(contracts[id].performanceScore);
        FHE.allowThis(contracts[id].reliabilityRatingBps);
        FHE.allowThis(_totalContracted);
        emit ContractIssued(id, category, programName);
        emit ContractAwarded(id, primeContractor);
    }

    function submitSubBid(
        uint256 contractId,
        string calldata component,
        SecurityClearance clearance,
        externalEuint64 encBid, bytes calldata bProof,
        externalEuint32 encCapability, bytes calldata cProof
    ) external onlyClearance(clearance) whenNotPaused nonReentrant {
        DefenseContract storage c = contracts[contractId];
        require(uint8(contractorClearance[msg.sender]) >= uint8(c.classification), "Insufficient clearance");
        euint64 bid = FHE.fromExternal(encBid, bProof);
        euint32 capability = FHE.fromExternal(encCapability, cProof);
        subBids[contractId].push(SubcontractorBid({
            contractId: contractId, subcontractor: msg.sender,
            systemComponent: component, bidValueUSD: bid,
            capabilityScore: capability, clearanceLevel: clearance, awarded: false
        }));
        FHE.allowThis(bid); FHE.allow(bid, msg.sender);
        FHE.allow(bid, c.primeContractor);
        FHE.allowThis(capability);
        emit SubBidSubmitted(contractId, msg.sender, component);
    }

    function updatePerformance(
        uint256 contractId,
        externalEuint32 encPerf, bytes calldata pProof,
        externalEuint32 encReliability, bytes calldata rProof
    ) external onlyOfficer {
        DefenseContract storage c = contracts[contractId];
        c.performanceScore = FHE.fromExternal(encPerf, pProof);
        c.reliabilityRatingBps = FHE.fromExternal(encReliability, rProof);
        FHE.allowThis(c.performanceScore); FHE.allow(c.performanceScore, c.primeContractor);
        FHE.allowThis(c.reliabilityRatingBps); FHE.allow(c.reliabilityRatingBps, c.primeContractor);
    }

    function confirmDelivery(uint256 contractId) external onlyOfficer {
        contracts[contractId].status = ContractStatus.Delivered;
        emit DeliveryConfirmed(contractId);
    }

    function allocateBudget(externalEuint64 encBudget, bytes calldata proof) external onlyOwner {
        euint64 budget = FHE.fromExternal(encBudget, proof);
        _totalDefenseBudget = FHE.add(_totalDefenseBudget, budget);
        FHE.allowThis(_totalDefenseBudget);
    }

    function allowDefenseStats(address viewer) external onlyOwner {
        FHE.allow(_totalDefenseBudget, viewer);
        FHE.allow(_totalContracted, viewer);
    }
}
