// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateAgeVerification - Confidential age gate with encrypted birthdate and zero-disclosure proofs
contract PrivateAgeVerification is ZamaEthereumConfig, Ownable {
    struct AgeCredential {
        euint8 verifiedAge;     // encrypted age (not birthdate)
        uint256 issuedAt;
        uint256 expiryDate;
        bool active;
        address issuer;
    }

    mapping(address => AgeCredential) private credentials;
    mapping(address => bool) public isAgeVerifier;
    mapping(address => mapping(uint256 => bool)) public hasAccessedGate; // user => gateId => accessed
    mapping(uint256 => uint8) public gateMinimumAge; // plaintext gate minimum age

    euint8 private _defaultMinAge;
    uint256 public gateCount;
    uint256 public totalVerified;

    event CredentialIssued(address indexed subject);
    event AgeGateCreated(uint256 indexed gateId, uint8 minimumAge);
    event AgeGatePassed(uint256 indexed gateId, address subject);
    event AgeGateFailed(uint256 indexed gateId, address subject);

    constructor(externalEuint8 encDefaultAge, bytes memory proof) Ownable(msg.sender) {
        _defaultMinAge = FHE.fromExternal(encDefaultAge, proof);
        FHE.allowThis(_defaultMinAge);
        isAgeVerifier[msg.sender] = true;
    }

    function addVerifier(address v) external onlyOwner { isAgeVerifier[v] = true; }

    function issueAgeCredential(address subject, externalEuint8 encAge, bytes calldata proof, uint256 validityDays) external {
        require(isAgeVerifier[msg.sender], "Not verifier");
        euint8 age = FHE.fromExternal(encAge, proof);
        credentials[subject] = AgeCredential({
            verifiedAge: age, issuedAt: block.timestamp,
            expiryDate: block.timestamp + validityDays * 1 days, active: true, issuer: msg.sender
        });
        FHE.allowThis(credentials[subject].verifiedAge);
        FHE.allow(credentials[subject].verifiedAge, subject);
        totalVerified++;
        emit CredentialIssued(subject);
    }

    function revokeCredential(address subject) external {
        require(isAgeVerifier[msg.sender], "Not verifier");
        credentials[subject].active = false;
    }

    function createAgeGate(uint8 minimumAge) external onlyOwner returns (uint256 gateId) {
        gateId = gateCount++;
        gateMinimumAge[gateId] = minimumAge;
        emit AgeGateCreated(gateId, minimumAge);
    }

    function passAgeGate(uint256 gateId) external returns (ebool passes) {
        AgeCredential storage cred = credentials[msg.sender];
        require(cred.active && block.timestamp < cred.expiryDate, "Invalid credential");
        uint8 required = gateMinimumAge[gateId];
        passes = FHE.ge(cred.verifiedAge, FHE.asEuint8(required));
        FHE.allow(passes, msg.sender);
        FHE.allowThis(passes);
        if (FHE.isInitialized(passes)) {
            hasAccessedGate[msg.sender][gateId] = true;
            emit AgeGatePassed(gateId, msg.sender);
        } else {
            emit AgeGateFailed(gateId, msg.sender);
        }
    }

    function allowAgeData(address viewer) external {
        FHE.allow(credentials[msg.sender].verifiedAge, viewer);
    }

    function verifierViewAge(address subject, address viewer) external {
        require(isAgeVerifier[msg.sender], "Not verifier");
        FHE.allow(credentials[subject].verifiedAge, viewer);
    }
}
