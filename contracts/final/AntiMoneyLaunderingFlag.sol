// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title AntiMoneyLaunderingFlag - AML compliance system with encrypted risk scores and transaction flagging
contract AntiMoneyLaunderingFlag is ZamaEthereumConfig, Ownable {
    struct AMLProfile {
        euint16 riskScore;          // encrypted 0-1000 (1000 = highest risk)
        euint32 transactionCount;
        euint64 highestTxVolume;    // encrypted largest single transaction
        euint64 monthlyVolume;      // encrypted monthly tx volume
        bool sanctioned;
        uint256 lastUpdated;
    }

    mapping(address => AMLProfile) private profiles;
    mapping(address => bool) public isAMLOfficer;
    mapping(address => bool) public isFinancialInstitution;
    euint16 private _highRiskThreshold;
    euint64 private _reportingThreshold;

    event ProfileCreated(address indexed subject);
    event RiskScoreUpdated(address indexed subject);
    event AccountSanctioned(address indexed subject);
    event SuspiciousActivityReported(address indexed subject, address reporter);

    constructor(externalEuint16 encHighRisk, bytes memory hrProof,
                externalEuint64 encReportingThreshold, bytes memory rtProof) Ownable(msg.sender) {
        _highRiskThreshold = FHE.fromExternal(encHighRisk, hrProof);
        _reportingThreshold = FHE.fromExternal(encReportingThreshold, rtProof);
        FHE.allowThis(_highRiskThreshold);
        FHE.allowThis(_reportingThreshold);
        isAMLOfficer[msg.sender] = true;
    }

    function addAMLOfficer(address o) external onlyOwner { isAMLOfficer[o] = true; }
    function addFinancialInstitution(address fi) external onlyOwner { isFinancialInstitution[fi] = true; }

    function createProfile(address subject) external {
        require(isFinancialInstitution[msg.sender] || isAMLOfficer[msg.sender], "Unauthorized");
        profiles[subject] = AMLProfile({
            riskScore: FHE.asEuint16(0), transactionCount: FHE.asEuint32(0),
            highestTxVolume: FHE.asEuint64(0), monthlyVolume: FHE.asEuint64(0),
            sanctioned: false, lastUpdated: block.timestamp
        });
        FHE.allowThis(profiles[subject].riskScore);
        FHE.allowThis(profiles[subject].transactionCount);
        FHE.allowThis(profiles[subject].highestTxVolume);
        FHE.allowThis(profiles[subject].monthlyVolume);
        emit ProfileCreated(subject);
    }

    function recordTransaction(address subject, externalEuint64 encTxAmount, bytes calldata proof) external {
        require(isFinancialInstitution[msg.sender], "Not FI");
        euint64 amount = FHE.fromExternal(encTxAmount, proof);
        AMLProfile storage p = profiles[subject];
        p.transactionCount = FHE.add(p.transactionCount, FHE.asEuint32(1));
        p.monthlyVolume = FHE.add(p.monthlyVolume, amount);
        // Track if this is largest tx
        ebool isLargest = FHE.gt(amount, p.highestTxVolume);
        p.highestTxVolume = FHE.select(isLargest, amount, p.highestTxVolume);
        FHE.allowThis(p.transactionCount); FHE.allowThis(p.monthlyVolume); FHE.allowThis(p.highestTxVolume);
        // Auto-flag if above reporting threshold
        ebool requiresReporting = FHE.ge(amount, _reportingThreshold);
        if (FHE.isInitialized(requiresReporting)) {
            emit SuspiciousActivityReported(subject, msg.sender);
        }
    }

    function updateRiskScore(address subject, externalEuint16 encScore, bytes calldata proof) external {
        require(isAMLOfficer[msg.sender], "Not officer");
        euint16 score = FHE.fromExternal(encScore, proof);
        profiles[subject].riskScore = score;
        profiles[subject].lastUpdated = block.timestamp;
        FHE.allowThis(profiles[subject].riskScore);
        // Auto-sanction if high risk
        ebool isHighRisk = FHE.ge(score, _highRiskThreshold);
        if (FHE.isInitialized(isHighRisk)) {
            profiles[subject].sanctioned = true;
            emit AccountSanctioned(subject);
        }
        emit RiskScoreUpdated(subject);
    }

    function sanctionAccount(address subject) external {
        require(isAMLOfficer[msg.sender], "Not officer");
        profiles[subject].sanctioned = true;
        emit AccountSanctioned(subject);
    }

    function isSanctioned(address subject) external view returns (bool) {
        return profiles[subject].sanctioned;
    }

    function allowProfileData(address subject, address viewer) external {
        require(isAMLOfficer[msg.sender], "Not officer");
        FHE.allow(profiles[subject].riskScore, viewer);
        FHE.allow(profiles[subject].highestTxVolume, viewer);
        FHE.allow(profiles[subject].monthlyVolume, viewer);
    }
}
