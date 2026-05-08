// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ThresholdKeyVault - Encrypted secret sharing vault requiring M-of-N guardian approval
contract ThresholdKeyVault is ZamaEthereumConfig, Ownable {
    struct Secret {
        address owner;
        euint128 encryptedSecret;
        uint8 threshold;
        uint8 guardianCount;
        uint256 lockUntil;
        bool revealed;
    }

    struct RecoveryRequest {
        uint256 secretId;
        uint8 approvals;
        bool executed;
        mapping(address => bool) approved;
    }

    mapping(uint256 => Secret) public secrets;
    mapping(uint256 => address[]) public guardians;
    mapping(uint256 => mapping(address => bool)) public isGuardian;
    mapping(uint256 => RecoveryRequest) private recoveryRequests;
    uint256 public secretCount;
    uint256 public recoveryCount;

    event SecretStored(uint256 indexed secretId, address indexed owner);
    event RecoveryRequested(uint256 indexed requestId, uint256 indexed secretId);
    event RecoveryApproved(uint256 indexed requestId, address indexed guardian);
    event SecretRevealed(uint256 indexed secretId, uint256 indexed requestId);

    constructor() Ownable(msg.sender) {}

    function storeSecret(
        externalEuint128 calldata encSecret,
        bytes calldata inputProof,
        address[] calldata _guardians,
        uint8 threshold,
        uint256 lockDuration
    ) external returns (uint256 secretId) {
        require(threshold > 0 && threshold <= _guardians.length, "Invalid threshold");
        secretId = secretCount++;
        Secret storage s = secrets[secretId];
        s.owner = msg.sender;
        s.encryptedSecret = FHE.fromExternal(encSecret, inputProof);
        s.threshold = threshold;
        s.guardianCount = uint8(_guardians.length);
        s.lockUntil = block.timestamp + lockDuration;
        FHE.allowThis(s.encryptedSecret);
        FHE.allow(s.encryptedSecret, msg.sender);

        for (uint256 i = 0; i < _guardians.length; i++) {
            guardians[secretId].push(_guardians[i]);
            isGuardian[secretId][_guardians[i]] = true;
        }
        emit SecretStored(secretId, msg.sender);
    }

    function requestRecovery(uint256 secretId) external returns (uint256 requestId) {
        require(isGuardian[secretId][msg.sender], "Not a guardian");
        requestId = recoveryCount++;
        RecoveryRequest storage r = recoveryRequests[requestId];
        r.secretId = secretId;
        r.approvals = 1;
        r.approved[msg.sender] = true;
        emit RecoveryRequested(requestId, secretId);
    }

    function approveRecovery(uint256 requestId) external {
        RecoveryRequest storage r = recoveryRequests[requestId];
        require(!r.executed, "Executed");
        require(isGuardian[r.secretId][msg.sender], "Not a guardian");
        require(!r.approved[msg.sender], "Already approved");
        r.approved[msg.sender] = true;
        r.approvals++;
        emit RecoveryApproved(requestId, msg.sender);

        if (r.approvals >= secrets[r.secretId].threshold) {
            Secret storage s = secrets[r.secretId];
            require(block.timestamp > s.lockUntil, "Still locked");
            r.executed = true;
            for (uint256 i = 0; i < guardians[r.secretId].length; i++) {
                FHE.allow(s.encryptedSecret, guardians[r.secretId][i]);
            }
            s.revealed = true;
            emit SecretRevealed(r.secretId, requestId);
        }
    }
}
