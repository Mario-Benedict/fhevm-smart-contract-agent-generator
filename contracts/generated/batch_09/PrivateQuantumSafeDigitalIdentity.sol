// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateQuantumSafeDigitalIdentity
/// @notice Encrypted digital identity registry using post-quantum ready design patterns.
///         Hidden biometric hashes, confidential national ID scores, private KYC tiers,
///         and encrypted credential issuance timestamps.
contract PrivateQuantumSafeDigitalIdentity is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum KYCTier { None, Basic, Enhanced, Institutional, Sovereign }
    enum CredentialType { NationalID, Passport, DriversLicense, TaxID, ProfessionalLicense }

    struct DigitalIdentity {
        address holder;
        euint8  kycTier;               // encrypted KYC tier level
        euint32 identityScore;         // encrypted composite identity score
        euint64 biometricHashA;        // encrypted biometric hash segment A
        euint64 biometricHashB;        // encrypted biometric hash segment B
        euint32 countryCode;           // encrypted country code
        euint8  sanctionsFlag;         // encrypted sanctions screening flag
        euint8  pepFlag;               // encrypted politically exposed person flag
        bool active;
        uint256 registeredAt;
        uint256 lastVerifiedAt;
    }

    struct IssuedCredential {
        address holder;
        CredentialType credType;
        euint64 credentialHash;        // encrypted credential hash
        euint32 issuingAuthorityCode;  // encrypted issuing authority
        euint8  trustLevel;            // encrypted trust level 0-10
        uint256 issuedAt;
        uint256 expiresAt;
        bool revoked;
    }

    mapping(address => DigitalIdentity) private identities;
    mapping(uint256 => IssuedCredential) private credentials;
    mapping(address => uint256[]) private holderCredentials;
    mapping(address => bool) public isIssuer;
    mapping(address => bool) public isVerifier;

    uint256 public credentialCount;
    euint32 private _totalIdentitiesRegistered;
    euint32 private _totalActiveIdentities;

    event IdentityRegistered(address indexed holder);
    event IdentityVerified(address indexed holder, uint256 verifiedAt);
    event CredentialIssued(uint256 indexed credId, address holder, CredentialType credType);
    event CredentialRevoked(uint256 indexed credId);

    modifier onlyIssuer() {
        require(isIssuer[msg.sender] || msg.sender == owner(), "Not issuer");
        _;
    }

    modifier onlyVerifier() {
        require(isVerifier[msg.sender] || msg.sender == owner(), "Not verifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalIdentitiesRegistered = FHE.asEuint32(0);
        _totalActiveIdentities = FHE.asEuint32(0);
        FHE.allowThis(_totalIdentitiesRegistered);
        FHE.allowThis(_totalActiveIdentities);
        isIssuer[msg.sender] = true;
        isVerifier[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addIssuer(address i) external onlyOwner { isIssuer[i] = true; }
    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }

    function registerIdentity(
        externalEuint8 encKYCTier, bytes calldata ktProof,
        externalEuint32 encScore, bytes calldata scoreProof,
        externalEuint64 encBioA, bytes calldata bioAProof,
        externalEuint64 encBioB, bytes calldata bioBProof,
        externalEuint32 encCountry, bytes calldata cntryProof
    ) external whenNotPaused {
        require(!identities[msg.sender].active, "Already registered");
        euint8 tier = FHE.fromExternal(encKYCTier, ktProof);
        euint32 score = FHE.fromExternal(encScore, scoreProof);
        euint64 bioA = FHE.fromExternal(encBioA, bioAProof);
        euint64 bioB = FHE.fromExternal(encBioB, bioBProof);
        euint32 country = FHE.fromExternal(encCountry, cntryProof);
        identities[msg.sender].holder = msg.sender;
        identities[msg.sender].kycTier = tier;
        identities[msg.sender].identityScore = score;
        identities[msg.sender].biometricHashA = bioA;
        identities[msg.sender].biometricHashB = bioB;
        identities[msg.sender].countryCode = country;
        identities[msg.sender].sanctionsFlag = FHE.asEuint8(0);
        identities[msg.sender].pepFlag = FHE.asEuint8(0);
        identities[msg.sender].active = true;
        identities[msg.sender].registeredAt = block.timestamp;
        identities[msg.sender].lastVerifiedAt = block.timestamp;
        _totalIdentitiesRegistered = FHE.add(_totalIdentitiesRegistered, FHE.asEuint32(1));
        _totalActiveIdentities = FHE.add(_totalActiveIdentities, FHE.asEuint32(1));
        FHE.allowThis(identities[msg.sender].kycTier); FHE.allow(identities[msg.sender].kycTier, msg.sender);
        FHE.allowThis(identities[msg.sender].identityScore); FHE.allow(identities[msg.sender].identityScore, msg.sender);
        FHE.allowThis(identities[msg.sender].biometricHashA); FHE.allow(identities[msg.sender].biometricHashA, msg.sender);
        FHE.allowThis(identities[msg.sender].biometricHashB); FHE.allow(identities[msg.sender].biometricHashB, msg.sender);
        FHE.allowThis(identities[msg.sender].countryCode); FHE.allow(identities[msg.sender].countryCode, msg.sender);
        FHE.allowThis(identities[msg.sender].sanctionsFlag);
        FHE.allowThis(identities[msg.sender].pepFlag);
        FHE.allowThis(_totalIdentitiesRegistered);
        FHE.allowThis(_totalActiveIdentities);
        emit IdentityRegistered(msg.sender);
    }

    function setSanctionsFlags(
        address holder,
        externalEuint8 encSanctions, bytes calldata sProof,
        externalEuint8 encPEP, bytes calldata pepProof
    ) external onlyIssuer {
        DigitalIdentity storage id_ = identities[holder];
        id_.sanctionsFlag = FHE.fromExternal(encSanctions, sProof);
        id_.pepFlag = FHE.fromExternal(encPEP, pepProof);
        FHE.allowThis(id_.sanctionsFlag); FHE.allow(id_.sanctionsFlag, holder);
        FHE.allowThis(id_.pepFlag); FHE.allow(id_.pepFlag, holder);
    }

    function issueCredential(
        address holder,
        CredentialType credType,
        externalEuint64 encCredHash, bytes calldata chProof,
        externalEuint32 encAuthCode, bytes calldata authProof,
        externalEuint8 encTrustLevel, bytes calldata tlProof,
        uint256 validityDays
    ) external onlyIssuer whenNotPaused returns (uint256 credId) {
        require(identities[holder].active, "Identity not active");
        euint64 credHash = FHE.fromExternal(encCredHash, chProof);
        euint32 authCode = FHE.fromExternal(encAuthCode, authProof);
        euint8 trust = FHE.fromExternal(encTrustLevel, tlProof);
        credId = credentialCount++;
        credentials[credId] = IssuedCredential({
            holder: holder, credType: credType, credentialHash: credHash,
            issuingAuthorityCode: authCode, trustLevel: trust,
            issuedAt: block.timestamp, expiresAt: block.timestamp + validityDays * 1 days, revoked: false
        });
        holderCredentials[holder].push(credId);
        FHE.allowThis(credentials[credId].credentialHash); FHE.allow(credentials[credId].credentialHash, holder); FHE.allow(credentials[credId].credentialHash, msg.sender);
        FHE.allowThis(credentials[credId].issuingAuthorityCode);
        FHE.allowThis(credentials[credId].trustLevel); FHE.allow(credentials[credId].trustLevel, holder);
        emit CredentialIssued(credId, holder, credType);
    }

    function revokeCredential(uint256 credId) external onlyIssuer {
        credentials[credId].revoked = true;
        emit CredentialRevoked(credId);
    }

    function allowIdentityVerification(address holder, address verifier) external {
        require(msg.sender == holder || isIssuer[msg.sender], "Unauthorized");
        DigitalIdentity storage id_ = identities[holder];
        FHE.allow(id_.kycTier, verifier);
        FHE.allow(id_.identityScore, verifier);
        FHE.allow(id_.sanctionsFlag, verifier);
        FHE.allow(id_.pepFlag, verifier);
    }

    function allowRegistryStats(address viewer) external onlyOwner {
        FHE.allow(_totalIdentitiesRegistered, viewer);
        FHE.allow(_totalActiveIdentities, viewer);
    }
}
