// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedDecentralizedIdentityRegistry
/// @notice Encrypted DID registry: private KYC tier flags, hidden age verification,
///         confidential accreditation scores, and encrypted credential revocation lists.
contract EncryptedDecentralizedIdentityRegistry is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    struct IdentityRecord {
        address subject;
        euint8  kycTier;               // encrypted KYC level (0-3)
        euint8  amlRiskScore;          // encrypted AML score
        euint16 accreditationScore;    // encrypted accreditation
        euint8  ageVerified;           // encrypted age flag (1=verified 18+)
        euint8  revoked;               // encrypted revocation flag
        euint64 credentialExpiry;      // encrypted expiry timestamp
        address issuer;
        uint256 issuedAt;
    }

    mapping(address => IdentityRecord) private identities;
    mapping(address => bool) public isKYCProvider;
    mapping(address => bool) public isVerifier;

    event IdentityIssued(address indexed subject, address indexed issuer);
    event IdentityRevoked(address indexed subject);
    event CredentialUpdated(address indexed subject);

    modifier onlyKYCProvider() {
        require(isKYCProvider[msg.sender] || msg.sender == owner(), "Not KYC provider");
        _;
    }

    constructor() Ownable(msg.sender) {
        isKYCProvider[msg.sender] = true;
        isVerifier[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addKYCProvider(address p) external onlyOwner { isKYCProvider[p] = true; }
    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }

    function issueIdentity(
        address subject,
        externalEuint8  encKYCTier,   bytes calldata ktProof,
        externalEuint8  encAML,       bytes calldata amlProof,
        externalEuint16 encAccred,    bytes calldata accProof,
        externalEuint8  encAge,       bytes calldata ageProof,
        externalEuint64 encExpiry,    bytes calldata expProof
    ) external onlyKYCProvider whenNotPaused {
        euint8  kycTier = FHE.fromExternal(encKYCTier, ktProof);
        euint8  aml     = FHE.fromExternal(encAML, amlProof);
        euint16 accred  = FHE.fromExternal(encAccred, accProof);
        euint8  age     = FHE.fromExternal(encAge, ageProof);
        euint64 expiry  = FHE.fromExternal(encExpiry, expProof);
        identities[subject].subject = subject;
        identities[subject].kycTier = kycTier;
        identities[subject].amlRiskScore = aml;
        identities[subject].accreditationScore = accred;
        identities[subject].ageVerified = age;
        identities[subject].revoked = FHE.asEuint8(0);
        identities[subject].credentialExpiry = expiry;
        identities[subject].issuer = msg.sender;
        identities[subject].issuedAt = block.timestamp;
        FHE.allowThis(identities[subject].kycTier);            FHE.allow(identities[subject].kycTier, subject);
        FHE.allowThis(identities[subject].amlRiskScore);
        FHE.allowThis(identities[subject].accreditationScore); FHE.allow(identities[subject].accreditationScore, subject);
        FHE.allowThis(identities[subject].ageVerified);        FHE.allow(identities[subject].ageVerified, subject);
        FHE.allowThis(identities[subject].revoked);
        FHE.allowThis(identities[subject].credentialExpiry);   FHE.allow(identities[subject].credentialExpiry, subject);
        emit IdentityIssued(subject, msg.sender);
    }

    function revokeIdentity(address subject) external onlyKYCProvider {
        identities[subject].revoked = FHE.asEuint8(1);
        FHE.allowThis(identities[subject].revoked);
        emit IdentityRevoked(subject);
    }

    function updateKYCTier(address subject, externalEuint8 encTier, bytes calldata proof) external onlyKYCProvider {
        euint8 tier = FHE.fromExternal(encTier, proof);
        identities[subject].kycTier = tier;
        FHE.allowThis(identities[subject].kycTier); FHE.allow(identities[subject].kycTier, subject);
        emit CredentialUpdated(subject);
    }

    function grantVerifierAccess(address subject, address verifier) external {
        require(msg.sender == subject || isKYCProvider[msg.sender], "Not authorized");
        FHE.allow(identities[subject].kycTier, verifier);
        FHE.allow(identities[subject].ageVerified, verifier);
        FHE.allow(identities[subject].accreditationScore, verifier);
    }

    function getKYCTier(address subject) external view returns (euint8) { return identities[subject].kycTier; }
    function getAMLScore(address subject) external view returns (euint8) { return identities[subject].amlRiskScore; }
    function isActiveCredential(address subject) external view returns (bool) { return identities[subject].issuedAt > 0; }
}
