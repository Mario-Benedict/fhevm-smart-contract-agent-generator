// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateEnergyGridTokenizedCapacity
/// @notice Encrypted energy grid capacity tokenization: hidden grid node capacities,
///         private renewable energy certificate (REC) values, confidential curtailment
///         penalties, and encrypted demand response payment distributions.
contract PrivateEnergyGridTokenizedCapacity is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum EnergySource { Solar, Wind, Hydro, Nuclear, NaturalGas, Battery, Geothermal }
    enum GridZone { NorthernZone, SouthernZone, EasternZone, WesternZone, CentralZone }

    struct GridNode {
        address operator;
        EnergySource source;
        GridZone zone;
        string nodeRef;
        euint64 installedCapacityMW;   // encrypted capacity
        euint64 availableCapacityMW;   // encrypted available
        euint64 recValueUSD;           // encrypted REC value
        euint64 curtailmentPenaltyUSD; // encrypted penalty
        euint64 demandResponsePayUSD;  // encrypted DR payment earned
        euint16 capacityFactorBps;     // encrypted CF
        bool active;
    }

    struct CapacityToken {
        uint256 nodeId;
        address holder;
        euint64 capacityMW;            // encrypted capacity held
        euint64 purchasePriceUSD;      // encrypted price paid
        euint64 currentValueUSD;       // encrypted current value
        uint256 purchasedAt;
    }

    mapping(uint256 => GridNode) private nodes;
    mapping(uint256 => CapacityToken) private capacityTokens;
    mapping(address => bool) public isGridOperator;
    mapping(address => bool) public isEnergyRegulator;

    uint256 public nodeCount;
    uint256 public tokenCount;
    euint64 private _totalGridCapacityMW;
    euint64 private _totalRECValueUSD;
    euint64 private _totalDemandResponseUSD;

    event NodeRegistered(uint256 indexed id, EnergySource source, GridZone zone);
    event CapacityTokenized(uint256 indexed tokenId, uint256 nodeId);
    event DemandResponseTriggered(uint256 indexed nodeId, uint256 triggeredAt);
    event CurtailmentPenaltyApplied(uint256 indexed nodeId, uint256 appliedAt);

    modifier onlyGridOperator() {
        require(isGridOperator[msg.sender] || msg.sender == owner(), "Not grid operator");
        _;
    }

    modifier onlyEnergyRegulator() {
        require(isEnergyRegulator[msg.sender] || msg.sender == owner(), "Not energy regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalGridCapacityMW = FHE.asEuint64(0);
        _totalRECValueUSD = FHE.asEuint64(0);
        _totalDemandResponseUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalGridCapacityMW);
        FHE.allowThis(_totalRECValueUSD);
        FHE.allowThis(_totalDemandResponseUSD);
        isGridOperator[msg.sender] = true;
        isEnergyRegulator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addGridOperator(address op) external onlyOwner { isGridOperator[op] = true; }
    function addEnergyRegulator(address er) external onlyOwner { isEnergyRegulator[er] = true; }

    function registerNode(
        EnergySource source, GridZone zone, string calldata nodeRef,
        externalEuint64 encCapacity,  bytes calldata capProof,
        externalEuint64 encRECValue,  bytes calldata recProof,
        externalEuint16 encCapFactor, bytes calldata cfProof
    ) external onlyGridOperator whenNotPaused returns (uint256 id) {
        euint64 capacity  = FHE.fromExternal(encCapacity, capProof);
        euint64 recValue  = FHE.fromExternal(encRECValue, recProof);
        euint16 capFactor = FHE.fromExternal(encCapFactor, cfProof);
        id = nodeCount++;
        nodes[id].operator = msg.sender;
        nodes[id].source = source;
        nodes[id].zone = zone;
        nodes[id].nodeRef = nodeRef;
        nodes[id].installedCapacityMW = capacity;
        nodes[id].availableCapacityMW = capacity;
        nodes[id].recValueUSD = recValue;
        nodes[id].curtailmentPenaltyUSD = FHE.asEuint64(0);
        nodes[id].demandResponsePayUSD = FHE.asEuint64(0);
        nodes[id].capacityFactorBps = capFactor;
        nodes[id].active = true;
        _totalGridCapacityMW = FHE.add(_totalGridCapacityMW, capacity);
        _totalRECValueUSD = FHE.add(_totalRECValueUSD, recValue);
        FHE.allowThis(nodes[id].installedCapacityMW); FHE.allow(nodes[id].installedCapacityMW, msg.sender);
        FHE.allowThis(nodes[id].availableCapacityMW); FHE.allow(nodes[id].availableCapacityMW, msg.sender);
        FHE.allowThis(nodes[id].recValueUSD); FHE.allow(nodes[id].recValueUSD, msg.sender);
        FHE.allowThis(nodes[id].curtailmentPenaltyUSD);
        FHE.allowThis(nodes[id].demandResponsePayUSD); FHE.allow(nodes[id].demandResponsePayUSD, msg.sender);
        FHE.allowThis(nodes[id].capacityFactorBps);
        FHE.allowThis(_totalGridCapacityMW); FHE.allowThis(_totalRECValueUSD);
        emit NodeRegistered(id, source, zone);
    }

    function tokenizeCapacity(
        uint256 nodeId,
        externalEuint64 encCapacityMW, bytes calldata cmProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external onlyGridOperator whenNotPaused returns (uint256 tokenId) {
        GridNode storage n = nodes[nodeId];
        euint64 capMW = FHE.fromExternal(encCapacityMW, cmProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        ebool available = FHE.ge(n.availableCapacityMW, capMW);
        euint64 effCap = FHE.select(available, capMW, FHE.asEuint64(0));
        n.availableCapacityMW = FHE.sub(n.availableCapacityMW, effCap);
        tokenId = tokenCount++;
        capacityTokens[tokenId] = CapacityToken({
            nodeId: nodeId, holder: msg.sender, capacityMW: effCap,
            purchasePriceUSD: price, currentValueUSD: price, purchasedAt: block.timestamp
        });
        FHE.allowThis(n.availableCapacityMW); FHE.allow(n.availableCapacityMW, n.operator);
        FHE.allowThis(capacityTokens[tokenId].capacityMW); FHE.allow(capacityTokens[tokenId].capacityMW, msg.sender);
        FHE.allowThis(capacityTokens[tokenId].purchasePriceUSD); FHE.allow(capacityTokens[tokenId].purchasePriceUSD, msg.sender);
        FHE.allowThis(capacityTokens[tokenId].currentValueUSD); FHE.allow(capacityTokens[tokenId].currentValueUSD, msg.sender);
        emit CapacityTokenized(tokenId, nodeId);
    }

    function triggerDemandResponse(uint256 nodeId, externalEuint64 encPayment, bytes calldata proof) external onlyEnergyRegulator {
        GridNode storage n = nodes[nodeId];
        euint64 payment = FHE.fromExternal(encPayment, proof);
        n.demandResponsePayUSD = FHE.add(n.demandResponsePayUSD, payment);
        _totalDemandResponseUSD = FHE.add(_totalDemandResponseUSD, payment);
        FHE.allowThis(n.demandResponsePayUSD); FHE.allow(n.demandResponsePayUSD, n.operator);
        FHE.allowThis(_totalDemandResponseUSD);
        emit DemandResponseTriggered(nodeId, block.timestamp);
    }

    function applyCurtailmentPenalty(uint256 nodeId, externalEuint64 encPenalty, bytes calldata proof) external onlyEnergyRegulator {
        GridNode storage n = nodes[nodeId];
        euint64 penalty = FHE.fromExternal(encPenalty, proof);
        n.curtailmentPenaltyUSD = FHE.add(n.curtailmentPenaltyUSD, penalty);
        FHE.allowThis(n.curtailmentPenaltyUSD); FHE.allow(n.curtailmentPenaltyUSD, n.operator);
        emit CurtailmentPenaltyApplied(nodeId, block.timestamp);
    }

    function allowGridStats(address viewer) external onlyOwner {
        FHE.allow(_totalGridCapacityMW, viewer);
        FHE.allow(_totalRECValueUSD, viewer);
        FHE.allow(_totalDemandResponseUSD, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}