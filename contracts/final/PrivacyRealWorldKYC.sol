// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivacyRealWorldKYC
/// @notice KYC compliance system where identity verification scores and
///         AML risk ratings are encrypted. Protocols can check KYC status
///         without seeing raw identity data.
contract PrivacyRealWorldKYC is ZamaEthereumConfig, Ownable {
    enum KYCLevel { None, Basic, Standard, Enhanced, Institutional }

    struct KYCRecord {
        euint8 verificationScore;   // 0-100 encrypted
        euint8 amlRiskScore;        // 1=low, 2=medium, 3=high
        euint8 sanctionListScore;   // 0=clear, 1=watchlist, 2=blocked
        KYCLevel level;
        uint256 expiryDate;
        bool active;
        address verifier;
    }

    mapping(address => KYCRecord) private kycRecords;
    mapping(address => bool) public isVerifier;
    mapping(address => mapping(address => bool)) public userConsent; // user => protocol => consent
    euint8 private _minVerificationScore;

    event KYCRecordCreated(address indexed user, KYCLevel level);
    event KYCExpired(address indexed user);
    event ConsentGranted(address indexed user, address protocol);

    constructor(externalEuint8 encMinScore, bytes memory proof) Ownable(msg.sender) {
        _minVerificationScore = FHE.fromExternal(encMinScore, proof);
        FHE.allowThis(_minVerificationScore);
    }

    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }

    function grantConsent(address protocol) external {
        userConsent[msg.sender][protocol] = true;
        if (kycRecords[msg.sender].active) {
            FHE.allow(kycRecords[msg.sender].verificationScore, protocol);
            FHE.allow(kycRecords[msg.sender].amlRiskScore, protocol);
        }
        emit ConsentGranted(msg.sender, protocol);
    }

    function revokeConsent(address protocol) external {
        userConsent[msg.sender][protocol] = false;
    }

    function createKYCRecord(
        address user, KYCLevel level, uint256 expiryDate,
        externalEuint8 encScore, bytes calldata sProof,
        externalEuint8 encAML, bytes calldata aProof,
        externalEuint8 encSanction, bytes calldata snProof
    ) external {
        require(isVerifier[msg.sender], "Not verifier");
        kycRecords[user] = KYCRecord({
            verificationScore: FHE.fromExternal(encScore, sProof),
            amlRiskScore: FHE.fromExternal(encAML, aProof),
            sanctionListScore: FHE.fromExternal(encSanction, snProof),
            level: level, expiryDate: expiryDate,
            active: true, verifier: msg.sender
        });
        FHE.allowThis(kycRecords[user].verificationScore);
        FHE.allow(kycRecords[user].verificationScore, user);
        FHE.allow(kycRecords[user].verificationScore, msg.sender);
        FHE.allowThis(kycRecords[user].amlRiskScore);
        FHE.allow(kycRecords[user].amlRiskScore, user);
        FHE.allowThis(kycRecords[user].sanctionListScore);
        FHE.allow(kycRecords[user].sanctionListScore, user);
        emit KYCRecordCreated(user, level);
    }

    function checkKYC(address user) external view returns (bool active, KYCLevel level) {
        KYCRecord storage r = kycRecords[user];
        active = r.active && block.timestamp < r.expiryDate;
        level = r.level;
    }

    function verifyMinimumKYC(address user) external returns (bool) {
        require(userConsent[user][msg.sender], "No consent");
        KYCRecord storage r = kycRecords[user];
        if (!r.active || block.timestamp >= r.expiryDate) return false;
        ebool scoreOk = FHE.ge(r.verificationScore, _minVerificationScore);
        ebool noSanction = FHE.eq(r.sanctionListScore, FHE.asEuint8(0));
        ebool valid = FHE.and(scoreOk, noSanction);
        return FHE.isInitialized(valid);
    }

    function expireRecord(address user) external onlyOwner {
        require(block.timestamp >= kycRecords[user].expiryDate, "Not expired");
        kycRecords[user].active = false;
        emit KYCExpired(user);
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