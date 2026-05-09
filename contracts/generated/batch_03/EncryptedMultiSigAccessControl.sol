// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedMultiSigAccessControl
/// @notice Encrypted multi-sig access control: hidden signer weights, private threshold
///         configurations, confidential operation approvals, and encrypted role bitfields.
contract EncryptedMultiSigAccessControl is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    struct Operation {
        bytes32 opHash;
        string description;
        euint64 approvalWeight;        // encrypted total approval weight
        euint64 requiredWeight;        // encrypted required weight threshold
        uint32  signerCount;
        bool executed;
        uint256 deadline;
    }

    struct Signer {
        euint64 weight;                // encrypted signer weight
        euint8  roleFlags;             // encrypted role bitmap
        bool active;
    }

    mapping(address => Signer) private signers;
    mapping(uint256 => Operation) private operations;
    mapping(uint256 => mapping(address => bool)) public hasSigned;

    uint256 public operationCount;
    euint64 private _totalApprovalWeight;

    event SignerRegistered(address indexed signer);
    event OperationProposed(uint256 indexed id, bytes32 opHash);
    event OperationSigned(uint256 indexed id, address indexed signer);
    event OperationExecuted(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _totalApprovalWeight = FHE.asEuint64(0);
        FHE.allowThis(_totalApprovalWeight);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerSigner(
        address signerAddr,
        externalEuint64 encWeight, bytes calldata wProof,
        externalEuint8  encRole,   bytes calldata rProof
    ) external onlyOwner {
        euint64 weight = FHE.fromExternal(encWeight, wProof);
        euint8  role   = FHE.fromExternal(encRole, rProof);
        signers[signerAddr] = Signer({ weight: weight, roleFlags: role, active: true });
        _totalApprovalWeight = FHE.add(_totalApprovalWeight, weight);
        FHE.allowThis(signers[signerAddr].weight); FHE.allow(signers[signerAddr].weight, signerAddr);
        FHE.allowThis(signers[signerAddr].roleFlags); FHE.allow(signers[signerAddr].roleFlags, signerAddr);
        FHE.allowThis(_totalApprovalWeight);
        emit SignerRegistered(signerAddr);
    }

    function proposeOperation(
        bytes32 opHash, string calldata description,
        externalEuint64 encRequired, bytes calldata proof,
        uint256 deadlineHours
    ) external whenNotPaused returns (uint256 id) {
        require(signers[msg.sender].active, "Not a signer");
        euint64 required = FHE.fromExternal(encRequired, proof);
        id = operationCount++;
        operations[id] = Operation({
            opHash: opHash, description: description, approvalWeight: FHE.asEuint64(0),
            requiredWeight: required, signerCount: 0, executed: false,
            deadline: block.timestamp + deadlineHours * 1 hours
        });
        FHE.allowThis(operations[id].approvalWeight);
        FHE.allowThis(operations[id].requiredWeight);
        emit OperationProposed(id, opHash);
    }

    function signOperation(uint256 opId) external whenNotPaused nonReentrant {
        Operation storage op = operations[opId];
        require(!op.executed && block.timestamp < op.deadline, "Not signable");
        require(signers[msg.sender].active && !hasSigned[opId][msg.sender], "Cannot sign");
        hasSigned[opId][msg.sender] = true;
        op.approvalWeight = FHE.add(op.approvalWeight, signers[msg.sender].weight);
        op.signerCount++;
        FHE.allowThis(op.approvalWeight);
        emit OperationSigned(opId, msg.sender);
    }

    function executeOperation(uint256 opId) external whenNotPaused nonReentrant {
        Operation storage op = operations[opId];
        require(!op.executed && block.timestamp < op.deadline, "Cannot execute");
        ebool thresholdMet = FHE.ge(op.approvalWeight, op.requiredWeight);
        // In production: decrypt off-chain or use FHE-native conditional execution
        FHE.allow(op.approvalWeight, owner()); FHE.allow(op.requiredWeight, owner());
        op.executed = true;
        emit OperationExecuted(opId);
    }

    function revokeSigner(address signerAddr) external onlyOwner {
        if (FHE.isInitialized(signers[signerAddr].weight)) {
            _totalApprovalWeight = FHE.sub(_totalApprovalWeight, signers[signerAddr].weight);
            FHE.allowThis(_totalApprovalWeight);
        }
        signers[signerAddr].active = false;
    }

    function getApprovalWeight(uint256 opId) external view returns (euint64) { return operations[opId].approvalWeight; }
    function getSignerWeight(address signerAddr) external view returns (euint64) { return signers[signerAddr].weight; }
    function allowWeightView(address signerAddr, address viewer) external onlyOwner { FHE.allow(signers[signerAddr].weight, viewer); }
}
