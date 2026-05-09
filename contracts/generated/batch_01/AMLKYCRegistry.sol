// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AMLKYCRegistry - Anti-money laundering KYC registry with encrypted risk scores
contract AMLKYCRegistry is ZamaEthereumConfig, AccessControl {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    enum KYCStatus { Unverified, Pending, Verified, Rejected, Suspended }

    struct KYCRecord {
        KYCStatus status;
        euint8 riskScore;       // 0-100
        euint8 pepFlag;         // Politically Exposed Person flag
        euint8 sanctionsFlag;   // Sanctions list flag
        euint32 verifiedAt;
        uint32 expiresAt;
        address verifier;
    }

    mapping(address => KYCRecord) public records;
    mapping(address => bool) public whitelisted;

    event KYCSubmitted(address indexed subject);
    event KYCVerified(address indexed subject, address indexed verifier);
    event KYCRejected(address indexed subject);
    event KYCSuspended(address indexed subject);
    event RiskScoreUpdated(address indexed subject);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
    }

    function submitKYC(address subject) external onlyRole(COMPLIANCE_ROLE) {
        require(records[subject].status == KYCStatus.Unverified, "Already submitted");
        records[subject].status = KYCStatus.Pending;
        records[subject].riskScore = FHE.asEuint8(0);
        records[subject].pepFlag = FHE.asEuint8(0);
        records[subject].sanctionsFlag = FHE.asEuint8(0);
        FHE.allowThis(records[subject].riskScore);
        FHE.allowThis(records[subject].pepFlag);
        FHE.allowThis(records[subject].sanctionsFlag);
        emit KYCSubmitted(subject);
    }

    function verifyKYC(
        address subject,
        externalEuint8 encRisk,
        bytes calldata riskProof,
        externalEuint8 encPep,
        bytes calldata pepProof,
        externalEuint8 encSanctions,
        bytes calldata sanctionsProof,
        uint32 validityDays
    ) external onlyRole(VERIFIER_ROLE) {
        require(records[subject].status == KYCStatus.Pending, "Not pending");
        KYCRecord storage r = records[subject];
        r.riskScore = FHE.fromExternal(encRisk, riskProof);
        r.pepFlag = FHE.fromExternal(encPep, pepProof);
        r.sanctionsFlag = FHE.fromExternal(encSanctions, sanctionsProof);
        r.status = KYCStatus.Verified;
        r.verifiedAt = FHE.asEuint32(uint32(block.timestamp));
        r.expiresAt = uint32(block.timestamp) + validityDays * 1 days;
        r.verifier = msg.sender;
        FHE.allowThis(r.riskScore);
        FHE.allowThis(r.pepFlag);
        FHE.allowThis(r.sanctionsFlag);
        FHE.allowThis(r.verifiedAt);
        FHE.allow(r.riskScore, subject);
        FHE.allow(r.pepFlag, subject);
        whitelisted[subject] = true;
        emit KYCVerified(subject, msg.sender);
    }

    function suspendKYC(address subject) external onlyRole(COMPLIANCE_ROLE) {
        records[subject].status = KYCStatus.Suspended;
        whitelisted[subject] = false;
        emit KYCSuspended(subject);
    }

    function rejectKYC(address subject) external onlyRole(COMPLIANCE_ROLE) {
        records[subject].status = KYCStatus.Rejected;
        whitelisted[subject] = false;
        emit KYCRejected(subject);
    }

    function updateRiskScore(address subject, externalEuint8 encScore, bytes calldata inputProof)
        external
        onlyRole(COMPLIANCE_ROLE)
    {
        records[subject].riskScore = FHE.fromExternal(encScore, inputProof);
        FHE.allowThis(records[subject].riskScore);
        FHE.allow(records[subject].riskScore, subject);
        FHE.allow(records[subject].riskScore, msg.sender);
        emit RiskScoreUpdated(subject);
    }

    function isKYCValid(address subject) external view returns (bool) {
        KYCRecord storage r = records[subject];
        return r.status == KYCStatus.Verified && block.timestamp <= r.expiresAt;
    }
}
