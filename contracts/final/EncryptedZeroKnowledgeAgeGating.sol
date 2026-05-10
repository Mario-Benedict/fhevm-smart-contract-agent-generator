// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedZeroKnowledgeAgeGating
/// @notice ZK-like age verification via FHE: hidden user birthdate hashes,
///         encrypted age thresholds per service, private compliance status flags,
///         and confidential jurisdiction-specific age rules.
contract EncryptedZeroKnowledgeAgeGating is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ServiceType { AlcoholPurchase, GamblingAccess, AdultContent, FinancialProduct, VotingEligibility }
    enum JurisdictionCode { US, EU, UK, AU, JP, BR, CA }

    struct AgeCredential {
        address subject;
        euint32 birthYearHash;         // encrypted birth year (hashed)
        euint8  verifiedAgeOver18;     // encrypted flag
        euint8  verifiedAgeOver21;     // encrypted flag
        euint8  verifiedAgeOver65;     // encrypted flag
        euint8  jurisdictionCode;      // encrypted jurisdiction
        address issuer;
        uint256 issuedAt;
        uint256 expiryDate;
        bool active;
    }

    struct ServiceAccessLog {
        address user;
        ServiceType serviceType;
        euint8  accessGranted;         // encrypted grant flag
        uint256 accessedAt;
    }

    mapping(address => AgeCredential) private credentials;
    mapping(uint256 => ServiceAccessLog) private accessLogs;
    mapping(address => bool) public isAgeVerifier;
    mapping(address => bool) public isServiceProvider;

    uint256 public accessLogCount;
    euint32 private _totalVerifiedUsers;
    euint32 private _totalAccessGranted;
    euint32 private _totalAccessDenied;

    event CredentialIssued(address indexed subject, address indexed issuer);
    event CredentialRevoked(address indexed subject);
    event ServiceAccessed(uint256 indexed logId, address user, ServiceType serviceType);

    modifier onlyAgeVerifier() {
        require(isAgeVerifier[msg.sender] || msg.sender == owner(), "Not age verifier");
        _;
    }

    modifier onlyServiceProvider() {
        require(isServiceProvider[msg.sender] || msg.sender == owner(), "Not service provider");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalVerifiedUsers = FHE.asEuint32(0);
        _totalAccessGranted = FHE.asEuint32(0);
        _totalAccessDenied  = FHE.asEuint32(0);
        FHE.allowThis(_totalVerifiedUsers);
        FHE.allowThis(_totalAccessGranted);
        FHE.allowThis(_totalAccessDenied);
        isAgeVerifier[msg.sender] = true;
        isServiceProvider[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addAgeVerifier(address av) external onlyOwner { isAgeVerifier[av] = true; }
    function addServiceProvider(address sp) external onlyOwner { isServiceProvider[sp] = true; }

    function issueAgeCredential(
        address subject,
        externalEuint32 encBirthYearHash, bytes calldata byhProof,
        externalEuint8  encOver18,        bytes calldata o18Proof,
        externalEuint8  encOver21,        bytes calldata o21Proof,
        externalEuint8  encOver65,        bytes calldata o65Proof,
        externalEuint8  encJurisdiction,  bytes calldata jurProof,
        uint256 validDays
    ) external onlyAgeVerifier whenNotPaused {
        euint32 birthHash   = FHE.fromExternal(encBirthYearHash, byhProof);
        euint8  over18      = FHE.fromExternal(encOver18, o18Proof);
        euint8  over21      = FHE.fromExternal(encOver21, o21Proof);
        euint8  over65      = FHE.fromExternal(encOver65, o65Proof);
        euint8  jurisdiction= FHE.fromExternal(encJurisdiction, jurProof);
        credentials[subject].subject = subject;
        credentials[subject].birthYearHash = birthHash;
        credentials[subject].verifiedAgeOver18 = over18;
        credentials[subject].verifiedAgeOver21 = over21;
        credentials[subject].verifiedAgeOver65 = over65;
        credentials[subject].jurisdictionCode = jurisdiction;
        credentials[subject].issuer = msg.sender;
        credentials[subject].issuedAt = block.timestamp;
        credentials[subject].expiryDate = block.timestamp + validDays * 1 days;
        credentials[subject].active = true;
        _totalVerifiedUsers = FHE.add(_totalVerifiedUsers, FHE.asEuint32(1)); // [arithmetic_overflow_underflow]
        ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
        FHE.allowThis(credentials[subject].birthYearHash);
        FHE.allowThis(credentials[subject].verifiedAgeOver18); FHE.allow(credentials[subject].verifiedAgeOver18, subject);
        FHE.allowThis(credentials[subject].verifiedAgeOver21); FHE.allow(credentials[subject].verifiedAgeOver21, subject);
        FHE.allowThis(credentials[subject].verifiedAgeOver65); FHE.allow(credentials[subject].verifiedAgeOver65, subject);
        FHE.allowThis(credentials[subject].jurisdictionCode);
        FHE.allowThis(_totalVerifiedUsers);
        emit CredentialIssued(subject, msg.sender);
    }

    function checkServiceAccess(address user, ServiceType serviceType) external onlyServiceProvider whenNotPaused nonReentrant returns (uint256 logId) {
        AgeCredential storage cred = credentials[user];
        require(cred.active && block.timestamp < cred.expiryDate, "No valid credential");
        euint8 granted;
        if (serviceType == ServiceType.AlcoholPurchase || serviceType == ServiceType.GamblingAccess) {
            granted = cred.verifiedAgeOver21;
        } else if (serviceType == ServiceType.VotingEligibility) {
            granted = cred.verifiedAgeOver18;
        } else {
            granted = cred.verifiedAgeOver18;
        }
        logId = accessLogCount++;
        accessLogs[logId] = ServiceAccessLog({ user: user, serviceType: serviceType, accessGranted: granted, accessedAt: block.timestamp });
        ebool grantedBool = FHE.eq(granted, FHE.asEuint8(1));
        _totalAccessGranted = FHE.add(_totalAccessGranted, FHE.select(grantedBool, FHE.asEuint32(1), FHE.asEuint32(0)));
        _totalAccessDenied  = FHE.add(_totalAccessDenied,  FHE.select(grantedBool, FHE.asEuint32(0), FHE.asEuint32(1)));
        FHE.allowThis(accessLogs[logId].accessGranted); FHE.allow(accessLogs[logId].accessGranted, msg.sender);
        FHE.allowThis(_totalAccessGranted); FHE.allowThis(_totalAccessDenied);
        emit ServiceAccessed(logId, user, serviceType);
    }

    function revokeCredential(address subject) external onlyAgeVerifier {
        credentials[subject].active = false;
        emit CredentialRevoked(subject);
    }

    function grantServiceView(address user, address serviceProvider) external {
        require(msg.sender == user, "Not you");
        FHE.allow(credentials[user].verifiedAgeOver18, serviceProvider);
        FHE.allow(credentials[user].verifiedAgeOver21, serviceProvider);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalVerifiedUsers, viewer); FHE.allow(_totalAccessGranted, viewer); FHE.allow(_totalAccessDenied, viewer);
    }
}
