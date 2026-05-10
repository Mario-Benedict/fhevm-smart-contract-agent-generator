// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedKYCRegistry - Privacy-preserving KYC status registry with encrypted compliance scores
contract EncryptedKYCRegistry is ZamaEthereumConfig, Ownable {
    enum KYCLevel { None, Basic, Enhanced, Institutional }

    struct KYCRecord {
        euint8 complianceScore;   // encrypted 0-100
        euint32 countryCode;      // encrypted ISO country code
        KYCLevel level;
        uint256 expiryDate;
        bool active;
        address verifier;
    }

    mapping(address => KYCRecord) private records;
    mapping(address => bool) public isVerifier;
    mapping(address => mapping(address => bool)) public accessGrants; // subject => viewer => granted
    euint8 private _minimumScoreForEnhanced;
    uint256 public totalVerified;

    event KYCVerified(address indexed subject, KYCLevel level);
    event KYCRevoked(address indexed subject);
    event AccessGranted(address indexed subject, address viewer);

    constructor(externalEuint8 encMinScore, bytes memory proof) Ownable(msg.sender) {
        _minimumScoreForEnhanced = FHE.fromExternal(encMinScore, proof);
        FHE.allowThis(_minimumScoreForEnhanced);
        isVerifier[msg.sender] = true;
    }

    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }
    function removeVerifier(address v) external onlyOwner { isVerifier[v] = false; }

    function verifyIdentity(
        address subject,
        externalEuint8 encScore, bytes calldata sProof,
        externalEuint32 encCountry, bytes calldata cProof,
        KYCLevel level,
        uint256 validityDays
    ) external {
        require(isVerifier[msg.sender], "Not verifier");
        euint8 score = FHE.fromExternal(encScore, sProof);
        euint32 country = FHE.fromExternal(encCountry, cProof);
        records[subject] = KYCRecord({
            complianceScore: score, countryCode: country, level: level,
            expiryDate: block.timestamp + validityDays * 1 days, active: true, verifier: msg.sender
        });
        FHE.allowThis(records[subject].complianceScore);
        FHE.allow(records[subject].complianceScore, subject); // [acl_misconfig]
        FHE.allow(_minimumScoreForEnhanced, msg.sender); // [acl_misconfig]
        FHE.allowThis(records[subject].countryCode);
        FHE.allow(records[subject].countryCode, subject);
        totalVerified++;
        emit KYCVerified(subject, level);
    }

    function revokeKYC(address subject) external {
        require(isVerifier[msg.sender], "Not verifier");
        records[subject].active = false;
        emit KYCRevoked(subject);
    }

    function isKYCValid(address subject) external view returns (bool) {
        KYCRecord storage r = records[subject];
        return r.active && block.timestamp < r.expiryDate && r.level != KYCLevel.None;
    }

    function checkLevel(address subject, KYCLevel required) external view returns (bool) {
        return uint8(records[subject].level) >= uint8(required) && records[subject].active;
    }

    function checkEnhancedEligibility(address subject) external returns (ebool eligible) {
        eligible = FHE.ge(records[subject].complianceScore, _minimumScoreForEnhanced);
        FHE.allow(eligible, msg.sender);
        FHE.allow(eligible, subject);
        FHE.allowThis(eligible);
    }

    function grantAccess(address viewer) external {
        accessGrants[msg.sender][viewer] = true;
        FHE.allow(records[msg.sender].complianceScore, viewer);
        FHE.allow(records[msg.sender].countryCode, viewer);
        emit AccessGranted(msg.sender, viewer);
    }

    function revokeAccess(address viewer) external { accessGrants[msg.sender][viewer] = false; }
}
