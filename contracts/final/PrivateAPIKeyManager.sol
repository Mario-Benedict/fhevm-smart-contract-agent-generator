// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateAPIKeyManager - Encrypted API key lifecycle management with rate limiting and encrypted quotas
contract PrivateAPIKeyManager is ZamaEthereumConfig, Ownable {
    struct APIKey {
        euint64 keyHash;         // encrypted key hash
        euint32 monthlyQuota;    // encrypted requests/month limit
        euint32 requestsUsed;    // encrypted count
        euint8 permissionLevel;  // encrypted 1=read, 2=write, 3=admin
        uint256 expiresAt;
        bool active;
        address issuer;
    }

    mapping(bytes32 => APIKey) private keys;  // keyId => key
    mapping(address => bytes32[]) private userKeys;
    mapping(address => bool) public isAPIAdmin;
    uint256 public totalKeys;

    event KeyIssued(bytes32 indexed keyId, address holder);
    event KeyRevoked(bytes32 indexed keyId);
    event QuotaExceeded(bytes32 indexed keyId);
    event RequestLogged(bytes32 indexed keyId);

    constructor() Ownable(msg.sender) {
        isAPIAdmin[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isAPIAdmin[a] = true; }

    function issueKey(
        address holder,
        externalEuint64 encKeyHash, bytes calldata hProof,
        externalEuint32 encQuota, bytes calldata qProof,
        externalEuint8 encPermLevel, bytes calldata pProof,
        uint256 validityDays
    ) external returns (bytes32 keyId) {
        require(isAPIAdmin[msg.sender], "Not admin");
        euint64 kHash = FHE.fromExternal(encKeyHash, hProof);
        euint32 quota = FHE.fromExternal(encQuota, qProof);
        euint8 perm = FHE.fromExternal(encPermLevel, pProof);
        keyId = keccak256(abi.encodePacked(holder, block.timestamp, totalKeys++));
        keys[keyId] = APIKey({ keyHash: kHash, monthlyQuota: quota, requestsUsed: FHE.asEuint32(0),
            permissionLevel: perm, expiresAt: block.timestamp + validityDays * 1 days, active: true, issuer: msg.sender });
        FHE.allowThis(keys[keyId].keyHash);
        FHE.allow(keys[keyId].keyHash, holder);
        FHE.allowThis(keys[keyId].monthlyQuota);
        FHE.allow(keys[keyId].monthlyQuota, holder);
        FHE.allowThis(keys[keyId].requestsUsed);
        FHE.allow(keys[keyId].requestsUsed, holder);
        FHE.allowThis(keys[keyId].permissionLevel);
        FHE.allow(keys[keyId].permissionLevel, holder);
        userKeys[holder].push(keyId);
        emit KeyIssued(keyId, holder);
    }

    function logRequest(bytes32 keyId) external {
        require(isAPIAdmin[msg.sender], "Not admin");
        APIKey storage k = keys[keyId];
        require(k.active && block.timestamp < k.expiresAt, "Invalid key");
        k.requestsUsed = FHE.add(k.requestsUsed, FHE.asEuint32(1));
        FHE.allowThis(k.requestsUsed);
        // Check if quota exceeded
        ebool exceeded = FHE.ge(k.requestsUsed, k.monthlyQuota);
        if (FHE.isInitialized(exceeded)) {
            k.active = false;
            emit QuotaExceeded(keyId);
        }
        emit RequestLogged(keyId);
    }

    function checkPermission(bytes32 keyId, uint8 required) external returns (ebool hasPermission) {
        APIKey storage k = keys[keyId];
        require(k.active && block.timestamp < k.expiresAt, "Invalid");
        hasPermission = FHE.ge(k.permissionLevel, FHE.asEuint8(required));
        FHE.allow(hasPermission, msg.sender);
        FHE.allowThis(hasPermission);
    }

    function revokeKey(bytes32 keyId) external {
        require(isAPIAdmin[msg.sender], "Not admin");
        keys[keyId].active = false;
        emit KeyRevoked(keyId);
    }

    function resetQuota(bytes32 keyId) external {
        require(isAPIAdmin[msg.sender], "Not admin");
        keys[keyId].requestsUsed = FHE.asEuint32(0);
        keys[keyId].active = true;
        FHE.allowThis(keys[keyId].requestsUsed);
    }

    function allowKeyDetails(bytes32 keyId, address viewer) external {
        require(isAPIAdmin[msg.sender], "Not admin");
        FHE.allow(keys[keyId].monthlyQuota, viewer);
        FHE.allow(keys[keyId].requestsUsed, viewer);
        FHE.allow(keys[keyId].permissionLevel, viewer);
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