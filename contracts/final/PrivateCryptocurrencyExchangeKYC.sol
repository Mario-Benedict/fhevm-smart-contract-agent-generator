// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCryptocurrencyExchangeKYC
/// @notice Crypto exchange KYC/AML compliance: encrypted risk scores, encrypted
///         transaction volumes, and FATF travel rule compliance for large transfers.
contract PrivateCryptocurrencyExchangeKYC is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum KYCTier { Basic, Enhanced, Institutional, VIP }
    enum RiskCategory { Low, Medium, High, Prohibited }
    enum TravelRuleStatus { BelowThreshold, PendingVASP, Compliant, Rejected }

    struct UserKYC {
        address user;
        KYCTier tier;
        RiskCategory riskCategory;
        euint32 kycScore;               // encrypted KYC score (0-1000)
        euint32 amlScore;               // encrypted AML risk score
        euint64 dailyWithdrawalLimit;   // encrypted withdrawal limit
        euint64 totalVolumeUSD;         // encrypted cumulative trading volume
        euint64 largestSingleTxUSD;     // encrypted peak single transaction
        uint256 kycValidUntil;
        bool sanctionsCleared;
    }

    struct TravelRuleRecord {
        address originatorUser;
        address beneficiaryUser;
        string originatorVASP;
        string beneficiaryVASP;
        euint64 transferAmountUSD;      // encrypted transfer amount
        TravelRuleStatus status;
        uint256 submittedAt;
    }

    mapping(address => UserKYC) private kycRecords;
    mapping(uint256 => TravelRuleRecord) private travelRules;
    mapping(address => bool) public isComplianceOfficer;
    mapping(address => bool) public isVASP;                  // Virtual Asset Service Provider

    uint256 public travelRuleCount;
    euint64 private _totalComplianceVolume;
    euint64 private _totalTravelRuleVolume;

    event KYCApproved(address indexed user, KYCTier tier);
    event KYCRevoked(address indexed user, string reason);
    event TravelRuleSubmitted(uint256 indexed id, address originator, string destVASP);
    event TravelRuleApproved(uint256 indexed id);

    modifier onlyCompliance() {
        require(isComplianceOfficer[msg.sender] || msg.sender == owner(), "Not compliance officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalComplianceVolume = FHE.asEuint64(0);
        _totalTravelRuleVolume = FHE.asEuint64(0);
        FHE.allowThis(_totalComplianceVolume);
        FHE.allowThis(_totalTravelRuleVolume);
        isComplianceOfficer[msg.sender] = true;
        isVASP[msg.sender] = true;
    }

    function addComplianceOfficer(address c) external onlyOwner { isComplianceOfficer[c] = true; }
    function addVASP(address v) external onlyOwner { isVASP[v] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function approveKYC(
        address user, KYCTier tier, RiskCategory risk,
        externalEuint32 encKYCScore, bytes calldata kProof,
        externalEuint32 encAMLScore, bytes calldata aProof,
        externalEuint64 encDailyLimit, bytes calldata dProof,
        uint256 validDays
    ) external onlyCompliance whenNotPaused {
        euint32 kycScore = FHE.fromExternal(encKYCScore, kProof);
        euint32 amlScore = FHE.fromExternal(encAMLScore, aProof);
        euint64 dailyLimit = FHE.fromExternal(encDailyLimit, dProof);
        kycRecords[user].user = user;
        kycRecords[user].tier = tier;
        kycRecords[user].riskCategory = risk;
        kycRecords[user].kycScore = kycScore;
        kycRecords[user].amlScore = amlScore;
        kycRecords[user].dailyWithdrawalLimit = dailyLimit;
        kycRecords[user].totalVolumeUSD = FHE.asEuint64(0);
        kycRecords[user].largestSingleTxUSD = FHE.asEuint64(0);
        kycRecords[user].kycValidUntil = block.timestamp + validDays * 1 days;
        kycRecords[user].sanctionsCleared = true;
        FHE.allowThis(kycRecords[user].kycScore); FHE.allow(kycRecords[user].kycScore, user);
        FHE.allowThis(kycRecords[user].amlScore);
        FHE.allowThis(kycRecords[user].dailyWithdrawalLimit); FHE.allow(kycRecords[user].dailyWithdrawalLimit, user);
        FHE.allowThis(kycRecords[user].totalVolumeUSD); FHE.allow(kycRecords[user].totalVolumeUSD, user);
        FHE.allowThis(kycRecords[user].largestSingleTxUSD); FHE.allow(kycRecords[user].largestSingleTxUSD, user);
        emit KYCApproved(user, tier);
    }

    function recordTransaction(
        address user, externalEuint64 encAmount, bytes calldata proof
    ) external onlyCompliance {
        UserKYC storage k = kycRecords[user];
        euint64 amount = FHE.fromExternal(encAmount, proof);
        k.totalVolumeUSD = FHE.add(k.totalVolumeUSD, amount);
        // Update largest tx if current > previous max
        ebool isLarger = FHE.gt(amount, k.largestSingleTxUSD);
        k.largestSingleTxUSD = FHE.select(isLarger, amount, k.largestSingleTxUSD);
        _totalComplianceVolume = FHE.add(_totalComplianceVolume, amount);
        FHE.allowThis(k.totalVolumeUSD); FHE.allow(k.totalVolumeUSD, user);
        FHE.allowThis(k.largestSingleTxUSD); FHE.allow(k.largestSingleTxUSD, user);
        FHE.allowThis(_totalComplianceVolume);
    }

    function submitTravelRule(
        address beneficiary, string calldata originVASP, string calldata destVASP,
        externalEuint64 encAmount, bytes calldata proof
    ) external whenNotPaused returns (uint256 id) {
        require(isVASP[msg.sender], "Not VASP");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Travel rule triggered for amounts >= 1000 USD (simplified check)
        id = travelRuleCount++;
        travelRules[id] = TravelRuleRecord({
            originatorUser: msg.sender, beneficiaryUser: beneficiary,
            originatorVASP: originVASP, beneficiaryVASP: destVASP,
            transferAmountUSD: amount,
            status: TravelRuleStatus.PendingVASP,
            submittedAt: block.timestamp
        });
        _totalTravelRuleVolume = FHE.add(_totalTravelRuleVolume, amount);
        FHE.allowThis(travelRules[id].transferAmountUSD);
        FHE.allow(travelRules[id].transferAmountUSD, owner());
        FHE.allowThis(_totalTravelRuleVolume);
        emit TravelRuleSubmitted(id, msg.sender, destVASP);
    }

    function approveTravelRule(uint256 travelRuleId) external onlyCompliance {
        travelRules[travelRuleId].status = TravelRuleStatus.Compliant;
        emit TravelRuleApproved(travelRuleId);
    }

    function rejectTravelRule(uint256 travelRuleId) external onlyCompliance {
        travelRules[travelRuleId].status = TravelRuleStatus.Rejected;
    }

    function revokeKYC(address user, string calldata reason) external onlyCompliance {
        kycRecords[user].sanctionsCleared = false;
        emit KYCRevoked(user, reason);
    }

    function grantComplianceAccess(address auditor) external {
        UserKYC storage k = kycRecords[msg.sender];
        FHE.allowTransient(k.kycScore, auditor);
        FHE.allowTransient(k.amlScore, auditor);
        FHE.allowTransient(k.totalVolumeUSD, auditor);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalComplianceVolume, viewer);
        FHE.allow(_totalTravelRuleVolume, viewer);
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