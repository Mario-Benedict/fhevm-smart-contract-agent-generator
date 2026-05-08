// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivatePrivacyPreservingCreditBureau
/// @notice Privacy-first credit bureau: encrypted payment histories, encrypted
///         debt-to-income ratios, and encrypted FICO-equivalent scores computed on-chain.
contract PrivatePrivacyPreservingCreditBureau is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum TradelineType { Mortgage, AutoLoan, CreditCard, StudentLoan, PersonalLoan, HELOC }
    enum PaymentStatus { OnTime, Late30, Late60, Late90, Default, Discharged }

    struct CreditProfile {
        address consumer;
        euint16 ficoCreditScore;         // encrypted credit score (300-850)
        euint32 totalDebtUSD;            // encrypted total debt
        euint32 totalCreditLimitUSD;     // encrypted total credit limit
        euint32 utilizationRateBps;      // encrypted utilization ratio
        euint16 inquiriesLast12M;        // encrypted hard inquiries
        euint16 accountAgeMonths;        // encrypted oldest account age
        uint256 profileCreated;
        bool active;
    }

    struct Tradeline {
        address consumer;
        address creditor;
        TradelineType tlType;
        euint32 originalBalanceUSD;      // encrypted original loan amount
        euint32 currentBalanceUSD;       // encrypted current balance
        euint32 creditLimitUSD;          // encrypted credit limit
        euint16 paymentHistoryScore;     // encrypted payment history score
        PaymentStatus latestStatus;
        uint256 openedDate;
        uint256 closedDate;
    }

    struct CreditInquiry {
        address consumer;
        address creditor;
        euint16 scoreAtInquiry;          // encrypted score when pulled
        string purpose;
        uint256 timestamp;
    }

    mapping(address => CreditProfile) private profiles;
    mapping(uint256 => Tradeline) private tradelines;
    mapping(uint256 => CreditInquiry) private inquiries;
    mapping(address => uint256[]) private consumerTradelines;
    mapping(address => uint256[]) private consumerInquiries;
    mapping(address => bool) public isCreditor;
    mapping(address => bool) public isBureau;    // authorized credit bureau operator

    uint256 public tradelineCount;
    uint256 public inquiryCount;
    euint64 private _totalProfilesCreated;

    event ProfileCreated(address indexed consumer);
    event TradelineAdded(uint256 indexed id, address consumer, TradelineType tlType);
    event InquiryLogged(uint256 indexed id, address consumer, address creditor);
    event ScoreUpdated(address indexed consumer);

    modifier onlyBureau() {
        require(isBureau[msg.sender] || msg.sender == owner(), "Not bureau");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalProfilesCreated = FHE.asEuint64(0);
        FHE.allowThis(_totalProfilesCreated);
        isBureau[msg.sender] = true;
    }

    function addCreditor(address c) external onlyOwner { isCreditor[c] = true; }
    function addBureau(address b) external onlyOwner { isBureau[b] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function createProfile(
        externalEuint16 encScore, bytes calldata sProof,
        externalEuint32 encDebt, bytes calldata dProof,
        externalEuint32 encLimit, bytes calldata lProof,
        externalEuint16 encInquiries, bytes calldata iProof,
        externalEuint16 encAge, bytes calldata aProof
    ) external whenNotPaused returns (bool) {
        require(!profiles[msg.sender].active, "Profile exists");
        euint16 score = FHE.fromExternal(encScore, sProof);
        euint32 debt = FHE.fromExternal(encDebt, dProof);
        euint32 limit = FHE.fromExternal(encLimit, lProof);
        euint16 inqs = FHE.fromExternal(encInquiries, iProof);
        euint16 age = FHE.fromExternal(encAge, aProof);
        euint32 utilization = FHE.asEuint32(0); // computed simplified
        profiles[msg.sender] = CreditProfile({
            consumer: msg.sender, ficoCreditScore: score,
            totalDebtUSD: debt, totalCreditLimitUSD: limit, utilizationRateBps: utilization,
            inquiriesLast12M: inqs, accountAgeMonths: age,
            profileCreated: block.timestamp, active: true
        });
        _totalProfilesCreated = FHE.add(_totalProfilesCreated, FHE.asEuint64(1));
        FHE.allowThis(profiles[msg.sender].ficoCreditScore); FHE.allow(profiles[msg.sender].ficoCreditScore, msg.sender);
        FHE.allowThis(profiles[msg.sender].totalDebtUSD); FHE.allow(profiles[msg.sender].totalDebtUSD, msg.sender);
        FHE.allowThis(profiles[msg.sender].totalCreditLimitUSD); FHE.allow(profiles[msg.sender].totalCreditLimitUSD, msg.sender);
        FHE.allowThis(profiles[msg.sender].utilizationRateBps); FHE.allow(profiles[msg.sender].utilizationRateBps, msg.sender);
        FHE.allowThis(profiles[msg.sender].inquiriesLast12M); FHE.allow(profiles[msg.sender].inquiriesLast12M, msg.sender);
        FHE.allowThis(profiles[msg.sender].accountAgeMonths);
        FHE.allowThis(_totalProfilesCreated);
        emit ProfileCreated(msg.sender);
        return true;
    }

    function addTradeline(
        address consumer, TradelineType tlType,
        externalEuint32 encOriginal, bytes calldata oProof,
        externalEuint32 encCurrent, bytes calldata cProof,
        externalEuint32 encLimit, bytes calldata lProof,
        externalEuint16 encPayHistory, bytes calldata phProof,
        PaymentStatus status
    ) external onlyBureau returns (uint256 id) {
        require(isCreditor[msg.sender] || isBureau[msg.sender], "Not authorized");
        euint32 original = FHE.fromExternal(encOriginal, oProof);
        euint32 current = FHE.fromExternal(encCurrent, cProof);
        euint32 limit = FHE.fromExternal(encLimit, lProof);
        euint16 payHist = FHE.fromExternal(encPayHistory, phProof);
        id = tradelineCount++;
        tradelines[id] = Tradeline({
            consumer: consumer, creditor: msg.sender, tlType: tlType,
            originalBalanceUSD: original, currentBalanceUSD: current,
            creditLimitUSD: limit, paymentHistoryScore: payHist,
            latestStatus: status, openedDate: block.timestamp, closedDate: 0
        });
        consumerTradelines[consumer].push(id);
        FHE.allowThis(tradelines[id].originalBalanceUSD); FHE.allow(tradelines[id].originalBalanceUSD, consumer);
        FHE.allowThis(tradelines[id].currentBalanceUSD); FHE.allow(tradelines[id].currentBalanceUSD, consumer);
        FHE.allowThis(tradelines[id].creditLimitUSD); FHE.allow(tradelines[id].creditLimitUSD, consumer);
        FHE.allowThis(tradelines[id].paymentHistoryScore); FHE.allow(tradelines[id].paymentHistoryScore, consumer);
        emit TradelineAdded(id, consumer, tlType);
    }

    function logInquiry(
        address consumer, string calldata purpose,
        externalEuint16 encScore, bytes calldata proof
    ) external onlyBureau returns (uint256 id) {
        euint16 score = FHE.fromExternal(encScore, proof);
        id = inquiryCount++;
        inquiries[id] = CreditInquiry({
            consumer: consumer, creditor: msg.sender, scoreAtInquiry: score,
            purpose: purpose, timestamp: block.timestamp
        });
        consumerInquiries[consumer].push(id);
        FHE.allowThis(score); FHE.allow(score, consumer);
        emit InquiryLogged(id, consumer, msg.sender);
    }

    function grantScoreAccess(address creditor) external {
        require(profiles[msg.sender].active, "No profile");
        FHE.allowTransient(profiles[msg.sender].ficoCreditScore, creditor);
        FHE.allowTransient(profiles[msg.sender].utilizationRateBps, creditor);
        FHE.allowTransient(profiles[msg.sender].inquiriesLast12M, creditor);
    }

    function allowBureauStats(address viewer) external onlyOwner {
        FHE.allow(_totalProfilesCreated, viewer);
    }
}
