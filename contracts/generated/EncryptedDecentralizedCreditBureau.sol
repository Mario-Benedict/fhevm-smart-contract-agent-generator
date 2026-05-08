// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedDecentralizedCreditBureau
/// @notice Decentralized credit bureau: encrypted on-chain payment histories, encrypted DeFi protocol
///         engagement scores, encrypted wallet age and activity scores, and private credit report generation.
contract EncryptedDecentralizedCreditBureau is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct CreditProfile {
        address wallet;
        euint64 paymentHistoryScore;   // encrypted on-chain payment score 0-350
        euint64 debtUtilizationScore;  // encrypted borrowing utilization 0-300
        euint64 creditHistoryScore;    // encrypted wallet age / history 0-150
        euint64 newCreditScore;        // encrypted recent loan/query activity 0-100
        euint64 creditMixScore;        // encrypted diversity of credit types 0-100
        euint64 compositeScore;        // encrypted FICO-like total 0-1000
        euint64 totalOnChainDebt;      // encrypted total outstanding debt
        euint64 totalCreditLines;      // encrypted total available credit
        uint256 lastUpdated;
        bool initialized;
    }

    struct ProtocolEngagement {
        address wallet;
        euint64 aaveScore;       // encrypted Aave usage score
        euint64 compoundScore;   // encrypted Compound usage score
        euint64 makerScore;      // encrypted MakerDAO usage score
        euint64 dexVolume;       // encrypted DEX trading volume (last 12m)
        euint64 nftScore;        // encrypted NFT engagement score
        euint64 governanceScore; // encrypted governance participation
        uint256 calculatedAt;
    }

    struct CreditReport {
        address subject;
        address requester;
        euint64 reportedScore;   // encrypted score at report time
        euint64 reportFeeUSD;    // encrypted fee paid for report
        uint256 reportDate;
        uint256 expiryDate;
        bool consentGiven;
    }

    mapping(address => CreditProfile) private profiles;
    mapping(address => ProtocolEngagement) private engagements;
    mapping(uint256 => CreditReport) private reports;
    uint256 public reportCount;
    euint64 private _totalReportFees;
    mapping(address => bool) public isScoreOracle;
    mapping(address => bool) public isBureauAdmin;
    mapping(address => mapping(address => bool)) public reportConsent; // subject -> requester -> consent

    event ProfileInitialized(address indexed wallet);
    event ScoreUpdated(address indexed wallet);
    event ReportRequested(uint256 indexed reportId, address subject, address requester);
    event ConsentGranted(address indexed subject, address indexed requester);

    constructor() Ownable(msg.sender) {
        _totalReportFees = FHE.asEuint64(0);
        FHE.allowThis(_totalReportFees);
        isScoreOracle[msg.sender] = true;
        isBureauAdmin[msg.sender] = true;
    }

    function addOracle(address o) external onlyOwner { isScoreOracle[o] = true; }
    function addAdmin(address a) external onlyOwner { isBureauAdmin[a] = true; }

    function initializeProfile(address wallet) external {
        require(isScoreOracle[msg.sender], "Not oracle");
        require(!profiles[wallet].initialized, "Already initialized");
        profiles[wallet] = CreditProfile({
            wallet: wallet, paymentHistoryScore: FHE.asEuint64(175),
            debtUtilizationScore: FHE.asEuint64(150), creditHistoryScore: FHE.asEuint64(75),
            newCreditScore: FHE.asEuint64(50), creditMixScore: FHE.asEuint64(50),
            compositeScore: FHE.asEuint64(500), totalOnChainDebt: FHE.asEuint64(0),
            totalCreditLines: FHE.asEuint64(0), lastUpdated: block.timestamp, initialized: true
        });
        FHE.allowThis(profiles[wallet].paymentHistoryScore);
        FHE.allowThis(profiles[wallet].debtUtilizationScore);
        FHE.allowThis(profiles[wallet].creditHistoryScore);
        FHE.allowThis(profiles[wallet].newCreditScore);
        FHE.allowThis(profiles[wallet].creditMixScore);
        FHE.allowThis(profiles[wallet].compositeScore);
        FHE.allowThis(profiles[wallet].totalOnChainDebt);
        FHE.allowThis(profiles[wallet].totalCreditLines);
        FHE.allow(profiles[wallet].compositeScore, wallet);
        emit ProfileInitialized(wallet);
    }

    function updateCreditScores(
        address wallet,
        externalEuint64 encPayment, bytes calldata pProof,
        externalEuint64 encUtilization, bytes calldata uProof,
        externalEuint64 encHistory, bytes calldata hProof,
        externalEuint64 encDebt, bytes calldata dProof,
        externalEuint64 encLines, bytes calldata lProof
    ) external {
        require(isScoreOracle[msg.sender], "Not oracle");
        CreditProfile storage prof = profiles[wallet];
        require(prof.initialized, "Not initialized");
        prof.paymentHistoryScore = FHE.fromExternal(encPayment, pProof);
        prof.debtUtilizationScore = FHE.fromExternal(encUtilization, uProof);
        prof.creditHistoryScore = FHE.fromExternal(encHistory, hProof);
        prof.totalOnChainDebt = FHE.fromExternal(encDebt, dProof);
        prof.totalCreditLines = FHE.fromExternal(encLines, lProof);
        // Composite score = sum of component scores
        prof.compositeScore = FHE.add(
            FHE.add(FHE.add(prof.paymentHistoryScore, prof.debtUtilizationScore),
            FHE.add(prof.creditHistoryScore, prof.newCreditScore)), prof.creditMixScore);
        prof.lastUpdated = block.timestamp;
        FHE.allowThis(prof.paymentHistoryScore);
        FHE.allowThis(prof.debtUtilizationScore);
        FHE.allowThis(prof.creditHistoryScore);
        FHE.allowThis(prof.totalOnChainDebt);
        FHE.allowThis(prof.totalCreditLines);
        FHE.allowThis(prof.compositeScore);
        FHE.allow(prof.compositeScore, wallet);
        emit ScoreUpdated(wallet);
    }

    function updateProtocolEngagement(
        address wallet,
        externalEuint64 encAave, bytes calldata aProof,
        externalEuint64 encCompound, bytes calldata compProof,
        externalEuint64 encDEX, bytes calldata dexProof,
        externalEuint64 encGov, bytes calldata govProof
    ) external {
        require(isScoreOracle[msg.sender], "Not oracle");
        euint64 aave = FHE.fromExternal(encAave, aProof);
        euint64 compound = FHE.fromExternal(encCompound, compProof);
        euint64 dex = FHE.fromExternal(encDEX, dexProof);
        euint64 gov = FHE.fromExternal(encGov, govProof);
        engagements[wallet] = ProtocolEngagement({
            wallet: wallet, aaveScore: aave, compoundScore: compound,
            makerScore: FHE.asEuint64(0), dexVolume: dex,
            nftScore: FHE.asEuint64(0), governanceScore: gov, calculatedAt: block.timestamp
        });
        FHE.allowThis(engagements[wallet].aaveScore);
        FHE.allowThis(engagements[wallet].compoundScore);
        FHE.allowThis(engagements[wallet].dexVolume);
        FHE.allowThis(engagements[wallet].governanceScore);
        FHE.allow(engagements[wallet].aaveScore, wallet);
        FHE.allow(engagements[wallet].governanceScore, wallet);
        // Update credit mix score from engagement
        profiles[wallet].creditMixScore = FHE.div(FHE.add(aave, compound), 2);
        FHE.allowThis(profiles[wallet].creditMixScore);
    }

    function grantConsent(address requester) external {
        reportConsent[msg.sender][requester] = true;
        emit ConsentGranted(msg.sender, requester);
    }

    function requestReport(
        address subject,
        externalEuint64 encFee, bytes calldata proof,
        uint256 expiryDuration
    ) external nonReentrant returns (uint256 reportId) {
        require(reportConsent[subject][msg.sender], "No consent");
        require(profiles[subject].initialized, "No profile");
        euint64 fee = FHE.fromExternal(encFee, proof);
        reportId = reportCount++;
        reports[reportId] = CreditReport({
            subject: subject, requester: msg.sender,
            reportedScore: profiles[subject].compositeScore,
            reportFeeUSD: fee, reportDate: block.timestamp,
            expiryDate: block.timestamp + expiryDuration, consentGiven: true
        });
        _totalReportFees = FHE.add(_totalReportFees, fee);
        FHE.allowThis(reports[reportId].reportedScore);
        FHE.allow(reports[reportId].reportedScore, msg.sender);
        FHE.allow(reports[reportId].reportedScore, subject);
        FHE.allowThis(reports[reportId].reportFeeUSD);
        FHE.allowThis(_totalReportFees);
        emit ReportRequested(reportId, subject, msg.sender);
    }
}
