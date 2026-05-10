// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedBiometricAccessVault
/// @notice Corporate vault with biometric-backed encrypted access tokens.
///         Access credentials, clearance levels, and audit trails are encrypted.
contract EncryptedBiometricAccessVault is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum AccessZone { Lobby, Office, Server, Laboratory, Vault, Executive }
    enum CredentialStatus { Pending, Active, Suspended, Revoked }

    struct BiometricCredential {
        euint64 biometricHashHigh;
        euint64 biometricHashLow;
        euint8 clearanceLevel;
        euint32 accessZoneMask;
        euint32 failedAttemptCount;
        CredentialStatus status;
        uint256 issuedAt;
        uint256 expiresAt;
    }

    struct VaultItem {
        string itemLabel;
        euint64 encryptedContent;
        euint8 requiredClearance;
        bool active;
    }

    mapping(address => BiometricCredential) private credentials;
    mapping(uint256 => VaultItem) private vaultItems;
    mapping(address => bool) public isSecurityAdmin;

    uint256 public vaultItemCount;
    euint64 private _totalSuccessfulAccesses;
    euint64 private _totalFailedAccesses;

    event CredentialIssued(address indexed holder, uint256 expiresAt);
    event CredentialRevoked(address indexed holder);
    event VaultItemRegistered(uint256 indexed itemId, string label);
    event AccessAttempted(address indexed holder, AccessZone zone);

    modifier onlySecAdmin() {
        require(isSecurityAdmin[msg.sender] || msg.sender == owner(), "Not security admin");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSuccessfulAccesses = FHE.asEuint64(0);
        _totalFailedAccesses = FHE.asEuint64(0);
        FHE.allowThis(_totalSuccessfulAccesses);
        FHE.allowThis(_totalFailedAccesses);
        isSecurityAdmin[msg.sender] = true;
    }

    function addSecurityAdmin(address admin) external onlyOwner { isSecurityAdmin[admin] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function issueCredential(
        address holder,
        externalEuint64 encBioHigh, bytes calldata bhProof,
        externalEuint64 encBioLow, bytes calldata blProof,
        externalEuint8 encClearance, bytes calldata clrProof,
        externalEuint32 encZoneMask, bytes calldata zoneProof,
        uint256 validityDuration
    ) external onlySecAdmin whenNotPaused {
        BiometricCredential storage cred = credentials[holder];
        cred.biometricHashHigh = FHE.fromExternal(encBioHigh, bhProof);
        cred.biometricHashLow = FHE.fromExternal(encBioLow, blProof);
        cred.clearanceLevel = FHE.fromExternal(encClearance, clrProof);
        cred.accessZoneMask = FHE.fromExternal(encZoneMask, zoneProof);
        cred.failedAttemptCount = FHE.asEuint32(0);
        cred.status = CredentialStatus.Active;
        cred.issuedAt = block.timestamp;
        cred.expiresAt = block.timestamp + validityDuration;
        FHE.allowThis(cred.biometricHashHigh); FHE.allow(cred.biometricHashHigh, holder);
        FHE.allowThis(cred.biometricHashLow); FHE.allow(cred.biometricHashLow, holder);
        FHE.allowThis(cred.clearanceLevel); FHE.allow(cred.clearanceLevel, holder);
        FHE.allowThis(cred.accessZoneMask); FHE.allow(cred.accessZoneMask, holder);
        FHE.allowThis(cred.failedAttemptCount); FHE.allow(cred.failedAttemptCount, holder);
        emit CredentialIssued(holder, cred.expiresAt);
    }

    function requestAccess(
        AccessZone zone,
        externalEuint64 encBioHigh, bytes calldata bhProof,
        externalEuint64 encBioLow, bytes calldata blProof
    ) external nonReentrant whenNotPaused {
        BiometricCredential storage cred = credentials[msg.sender];
        require(cred.status == CredentialStatus.Active, "Credential not active");
        require(block.timestamp < cred.expiresAt, "Credential expired");
        euint64 submitHigh = FHE.fromExternal(encBioHigh, bhProof);
        euint64 submitLow = FHE.fromExternal(encBioLow, blProof);
        ebool bioMatch = FHE.and(FHE.eq(submitHigh, cred.biometricHashHigh), FHE.eq(submitLow, cred.biometricHashLow));
        uint32 zoneBit = uint32(1) << uint32(zone);
        ebool zoneAllowed = FHE.gt(FHE.and(cred.accessZoneMask, FHE.asEuint32(zoneBit)), FHE.asEuint32(0));
        ebool accessGranted = FHE.and(bioMatch, zoneAllowed);
        euint64 token = FHE.select(accessGranted, FHE.randEuint64(), FHE.asEuint64(0));
        euint32 failIncr = FHE.select(accessGranted, FHE.asEuint32(0), FHE.asEuint32(1));
        cred.failedAttemptCount = FHE.add(cred.failedAttemptCount, failIncr);
        _totalSuccessfulAccesses = FHE.add(_totalSuccessfulAccesses, FHE.select(accessGranted, FHE.asEuint64(1), FHE.asEuint64(0)));
        _totalFailedAccesses = FHE.add(_totalFailedAccesses, FHE.select(accessGranted, FHE.asEuint64(0), FHE.asEuint64(1)));
        FHE.allowThis(token); FHE.allow(token, msg.sender);
        FHE.allowThis(cred.failedAttemptCount); FHE.allow(cred.failedAttemptCount, msg.sender);
        FHE.allowThis(_totalSuccessfulAccesses); FHE.allowThis(_totalFailedAccesses);
        emit AccessAttempted(msg.sender, zone);
    }

    function registerVaultItem(
        string calldata label,
        externalEuint64 encContent, bytes calldata contentProof,
        externalEuint8 encReqClearance, bytes calldata clrProof
    ) external onlySecAdmin returns (uint256 itemId) {
        itemId = vaultItemCount++;
        vaultItems[itemId].itemLabel = label;
        vaultItems[itemId].encryptedContent = FHE.fromExternal(encContent, contentProof);
        vaultItems[itemId].requiredClearance = FHE.fromExternal(encReqClearance, clrProof);
        vaultItems[itemId].active = true;
        FHE.allowThis(vaultItems[itemId].encryptedContent);
        FHE.allowThis(vaultItems[itemId].requiredClearance);
        emit VaultItemRegistered(itemId, label);
    }

    function grantItemAccess(uint256 itemId, address viewer) external onlySecAdmin {
        FHE.allow(vaultItems[itemId].encryptedContent, viewer);
    }

    function revokeCredential(address holder) external onlySecAdmin {
        credentials[holder].status = CredentialStatus.Revoked;
        emit CredentialRevoked(holder);
    }

    function allowVaultStats(address viewer) external onlyOwner {
        FHE.allow(_totalSuccessfulAccesses, viewer);
        FHE.allow(_totalFailedAccesses, viewer);
    }
}
