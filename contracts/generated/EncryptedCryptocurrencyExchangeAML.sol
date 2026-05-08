// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCryptocurrencyExchangeAML
/// @notice Crypto exchange AML compliance: encrypted transaction risk scores, encrypted suspicious
///         pattern flags, encrypted VASP risk ratings, and confidential SAR (Suspicious Activity Report) thresholds.
contract EncryptedCryptocurrencyExchangeAML is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct UserProfile {
        euint64 transactionVolume30d;  // encrypted 30-day volume
        euint64 riskScore;             // encrypted composite risk 0-1000
        euint64 sarThreshold;          // encrypted SAR filing threshold
        euint64 jurisdictionRisk;      // encrypted jurisdiction risk 0-1000
        euint8 kycLevel;               // encrypted KYC completion level
        bool flaggedForReview;
        bool sanctioned;
    }

    struct Transaction {
        address sender;
        address recipient;
        euint64 amountUSD;         // encrypted amount
        euint64 mlRiskScore;       // encrypted ML-detected risk score
        euint64 velocityScore;     // encrypted velocity anomaly score
        string chainRef;           // blockchain transaction reference
        uint256 timestamp;
        bool flagged;
        bool reported;
    }

    struct VASPRating {
        string vaspName;
        string jurisdiction;
        euint64 riskRating;       // encrypted VASP risk score 0-1000
        euint64 transactionLimit; // encrypted per-tx limit with this VASP
        bool blocked;
    }

    mapping(address => UserProfile) private profiles;
    mapping(uint256 => Transaction) private transactions;
    mapping(uint256 => VASPRating) private vasps;
    uint256 public txCount;
    uint256 public vaspCount;
    euint64 private _totalSuspiciousVolume;
    mapping(address => bool) public isComplianceOfficer;
    mapping(address => bool) public isMLOracle;

    event ProfileCreated(address indexed user);
    event TransactionRecorded(uint256 indexed txId, bool flagged);
    event SARFiled(uint256 indexed txId, address user);
    event VASPAdded(uint256 indexed vaspId, string name);
    event UserSanctioned(address indexed user);

    constructor() Ownable(msg.sender) {
        _totalSuspiciousVolume = FHE.asEuint64(0);
        FHE.allowThis(_totalSuspiciousVolume);
        isComplianceOfficer[msg.sender] = true;
        isMLOracle[msg.sender] = true;
    }

    function addOfficer(address o) external onlyOwner { isComplianceOfficer[o] = true; }
    function addMLOracle(address ml) external onlyOwner { isMLOracle[ml] = true; }

    function createProfile(
        address user,
        externalEuint64 encSARThreshold, bytes calldata sProof,
        externalEuint64 encJurisdictionRisk, bytes calldata jProof,
        externalEuint8 encKYCLevel, bytes calldata kProof
    ) external {
        require(isComplianceOfficer[msg.sender], "Not officer");
        euint64 sarThresh = FHE.fromExternal(encSARThreshold, sProof);
        euint64 jurRisk = FHE.fromExternal(encJurisdictionRisk, jProof);
        euint8 kyc = FHE.fromExternal(encKYCLevel, kProof);
        profiles[user] = UserProfile({
            transactionVolume30d: FHE.asEuint64(0), riskScore: FHE.asEuint64(0),
            sarThreshold: sarThresh, jurisdictionRisk: jurRisk,
            kycLevel: kyc, flaggedForReview: false, sanctioned: false
        });
        FHE.allowThis(profiles[user].transactionVolume30d);
        FHE.allowThis(profiles[user].riskScore);
        FHE.allowThis(profiles[user].sarThreshold);
        FHE.allowThis(profiles[user].jurisdictionRisk);
        FHE.allowThis(profiles[user].kycLevel);
        FHE.allow(profiles[user].kycLevel, user);
        emit ProfileCreated(user);
    }

    function recordTransaction(
        address sender, address recipient, string calldata chainRef,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint64 encMLScore, bytes calldata mlProof,
        externalEuint64 encVelocity, bytes calldata vProof
    ) external returns (uint256 txId) {
        require(isMLOracle[msg.sender], "Not ML oracle");
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint64 mlScore = FHE.fromExternal(encMLScore, mlProof);
        euint64 velocity = FHE.fromExternal(encVelocity, vProof);
        bool flagged = true; // oracle determines off-chain, always store
        txId = txCount++;
        transactions[txId] = Transaction({
            sender: sender, recipient: recipient, amountUSD: amount,
            mlRiskScore: mlScore, velocityScore: velocity,
            chainRef: chainRef, timestamp: block.timestamp, flagged: flagged, reported: false
        });
        // Update sender profile
        UserProfile storage senderProfile = profiles[sender];
        if (FHE.isInitialized(senderProfile.transactionVolume30d)) {
            senderProfile.transactionVolume30d = FHE.add(senderProfile.transactionVolume30d, amount);
            senderProfile.riskScore = FHE.add(senderProfile.riskScore, FHE.div(mlScore, FHE.asEuint64(10)));
            FHE.allowThis(senderProfile.transactionVolume30d);
            FHE.allowThis(senderProfile.riskScore);
        }
        // Flag if above SAR threshold
        if (FHE.isInitialized(senderProfile.sarThreshold)) {
            ebool aboveSAR = FHE.ge(amount, senderProfile.sarThreshold);
            _totalSuspiciousVolume = FHE.add(_totalSuspiciousVolume, FHE.select(aboveSAR, amount, FHE.asEuint64(0)));
            FHE.allowThis(_totalSuspiciousVolume);
        }
        FHE.allowThis(transactions[txId].amountUSD);
        FHE.allowThis(transactions[txId].mlRiskScore);
        FHE.allowThis(transactions[txId].velocityScore);
        emit TransactionRecorded(txId, flagged);
    }

    function fileSAR(uint256 txId) external {
        require(isComplianceOfficer[msg.sender], "Not officer");
        transactions[txId].reported = true;
        profiles[transactions[txId].sender].flaggedForReview = true;
        FHE.allow(transactions[txId].amountUSD, owner());
        FHE.allow(transactions[txId].mlRiskScore, owner());
        emit SARFiled(txId, transactions[txId].sender);
    }

    function sanctionUser(address user) external onlyOwner {
        profiles[user].sanctioned = true;
        emit UserSanctioned(user);
    }

    function addVASP(
        string calldata name, string calldata jurisdiction,
        externalEuint64 encRisk, bytes calldata rProof,
        externalEuint64 encLimit, bytes calldata lProof
    ) external returns (uint256 vaspId) {
        require(isComplianceOfficer[msg.sender], "Not officer");
        euint64 risk = FHE.fromExternal(encRisk, rProof);
        euint64 limit = FHE.fromExternal(encLimit, lProof);
        vaspId = vaspCount++;
        vasps[vaspId] = VASPRating({ vaspName: name, jurisdiction: jurisdiction, riskRating: risk, transactionLimit: limit, blocked: false });
        FHE.allowThis(vasps[vaspId].riskRating);
        FHE.allowThis(vasps[vaspId].transactionLimit);
        emit VASPAdded(vaspId, name);
    }
}
