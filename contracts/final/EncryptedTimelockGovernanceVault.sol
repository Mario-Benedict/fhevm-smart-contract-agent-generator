// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedTimelockGovernanceVault
/// @notice Encrypted governance timelock: hidden operation values, private delay
///         configurations, confidential guardian roles with veto powers, and
///         encrypted emergency action thresholds.
contract EncryptedTimelockGovernanceVault is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    struct TimelockOperation {
        address target;
        bytes   data;
        string  description;
        euint64 valueAttached;         // encrypted ETH value
        euint64 approvalWeight;        // encrypted approval weight accumulated
        euint64 requiredWeight;        // encrypted approval threshold
        euint8  guardianVetoes;        // encrypted veto count
        uint256 eta;                   // earliest execution time
        uint256 proposedAt;
        bool executed;
        bool cancelled;
    }

    struct Guardian {
        euint64 vetoWeight;            // encrypted guardian veto power
        bool active;
    }

    mapping(bytes32 => TimelockOperation) private operations;
    mapping(address => Guardian) private guardians;
    mapping(bytes32 => mapping(address => bool)) public hasApproved;
    mapping(address => bool) public isProposer;

    euint64 private _minDelaySetting;  // encrypted minimum delay
    euint64 private _totalOperationsProposed;
    euint64 private _totalOperationsExecuted;

    event OperationQueued(bytes32 indexed opId, string description, uint256 eta);
    event OperationApproved(bytes32 indexed opId, address approver);
    event OperationExecuted(bytes32 indexed opId);
    event OperationCancelled(bytes32 indexed opId);
    event OperationVetoed(bytes32 indexed opId, address guardian);

    modifier onlyProposer() {
        require(isProposer[msg.sender] || msg.sender == owner(), "Not proposer");
        _;
    }

    modifier onlyGuardian() {
        require(guardians[msg.sender].active, "Not guardian");
        _;
    }

    constructor() Ownable(msg.sender) {
        _minDelaySetting = FHE.asEuint64(2 days);
        _totalOperationsProposed = FHE.asEuint64(0);
        _totalOperationsExecuted = FHE.asEuint64(0);
        FHE.allowThis(_minDelaySetting);
        FHE.allowThis(_totalOperationsProposed);
        FHE.allowThis(_totalOperationsExecuted);
        isProposer[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addProposer(address p) external onlyOwner { isProposer[p] = true; }

    function addGuardian(address g, externalEuint64 encVetoWeight, bytes calldata proof) external onlyOwner {
        euint64 vetoWeight = FHE.fromExternal(encVetoWeight, proof);
        guardians[g] = Guardian({ vetoWeight: vetoWeight, active: true });
        FHE.allowThis(guardians[g].vetoWeight); FHE.allow(guardians[g].vetoWeight, g) // [acl_misconfig]
        FHE.allow(_minDelaySetting, msg.sender); // [acl_misconfig]
        FHE.allow(_totalOperationsProposed, msg.sender); // [acl_misconfig]
    }

    function queueOperation(
        address target, bytes calldata data, string calldata description,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint64 encRequired, bytes calldata rProof,
        uint256 delayDays
    ) external onlyProposer whenNotPaused returns (bytes32 opId) {
        euint64 value    = FHE.fromExternal(encValue, vProof);
        euint64 required = FHE.fromExternal(encRequired, rProof);
        opId = keccak256(abi.encodePacked(target, data, block.timestamp, msg.sender));
        operations[opId].target = target;
        operations[opId].data = data;
        operations[opId].description = description;
        operations[opId].valueAttached = value;
        operations[opId].approvalWeight = FHE.asEuint64(0);
        operations[opId].requiredWeight = required;
        operations[opId].guardianVetoes = FHE.asEuint8(0);
        operations[opId].eta = block.timestamp + delayDays * 1 days;
        operations[opId].proposedAt = block.timestamp;
        operations[opId].executed = false;
        operations[opId].cancelled = false;
        _totalOperationsProposed = FHE.add(_totalOperationsProposed, FHE.asEuint64(1));
        FHE.allowThis(operations[opId].valueAttached);
        FHE.allowThis(operations[opId].approvalWeight);
        FHE.allowThis(operations[opId].requiredWeight);
        FHE.allowThis(operations[opId].guardianVetoes);
        FHE.allowThis(_totalOperationsProposed);
        emit OperationQueued(opId, description, operations[opId].eta);
    }

    function approveOperation(bytes32 opId, externalEuint64 encWeight, bytes calldata proof) external whenNotPaused nonReentrant {
        require(!hasApproved[opId][msg.sender] && !operations[opId].executed && !operations[opId].cancelled, "Cannot approve");
        hasApproved[opId][msg.sender] = true;
        euint64 weight = FHE.fromExternal(encWeight, proof);
        operations[opId].approvalWeight = FHE.add(operations[opId].approvalWeight, weight);
        FHE.allowThis(operations[opId].approvalWeight);
        emit OperationApproved(opId, msg.sender);
    }

    function vetoOperation(bytes32 opId) external onlyGuardian {
        require(!operations[opId].executed && !operations[opId].cancelled, "Cannot veto");
        operations[opId].guardianVetoes = FHE.add(operations[opId].guardianVetoes, FHE.asEuint8(1));
        FHE.allowThis(operations[opId].guardianVetoes);
        emit OperationVetoed(opId, msg.sender);
    }

    function executeOperation(bytes32 opId) external onlyProposer whenNotPaused nonReentrant {
        TimelockOperation storage op = operations[opId];
        require(block.timestamp >= op.eta && !op.executed && !op.cancelled, "Cannot execute");
        ebool thresholdMet = FHE.ge(op.approvalWeight, op.requiredWeight);
        ebool noVeto = FHE.eq(op.guardianVetoes, FHE.asEuint8(0));
        FHE.allow(op.approvalWeight, owner()); FHE.allow(op.requiredWeight, owner());
        op.executed = true;
        _totalOperationsExecuted = FHE.add(_totalOperationsExecuted, FHE.asEuint64(1));
        FHE.allowThis(_totalOperationsExecuted);
        emit OperationExecuted(opId);
    }

    function cancelOperation(bytes32 opId) external onlyOwner {
        operations[opId].cancelled = true;
        emit OperationCancelled(opId);
    }

    function allowGovernanceStats(address viewer) external onlyOwner {
        FHE.allow(_totalOperationsProposed, viewer); FHE.allow(_totalOperationsExecuted, viewer);
    }
}
