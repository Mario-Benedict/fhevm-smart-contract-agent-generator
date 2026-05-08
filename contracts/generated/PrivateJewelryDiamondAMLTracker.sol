// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateJewelryDiamond AMLTracker
/// @notice Anti-money laundering compliance for high-value jewelry transactions:
///         encrypted purchase amounts, beneficial ownership disclosure thresholds,
///         politically exposed person (PEP) flags, and suspicious transaction reports.
contract PrivateJewelryDiamondAMLTracker is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum TransactionType { PURCHASE, SALE, CONSIGNMENT, AUCTION_WIN, TRADE, GIFT }
    enum RiskLevel { LOW, MEDIUM, HIGH, VERY_HIGH, SANCTIONED }
    enum PaymentMethod { CASH, BANK_TRANSFER, CRYPTO, CREDIT_CARD, CHECK, MIXED }
    enum SARStatus { NONE, FILED, UNDER_INVESTIGATION, CLEARED }

    struct Customer {
        euint64 totalTransactionValue30Days;  // encrypted rolling 30d spend
        euint64 totalTransactionValue12Months;// encrypted rolling 12m spend
        euint64 riskScore;                    // encrypted AML risk score (0-1000)
        euint64 cashTransactionTotal;         // encrypted total cash payments
        euint32 transactionCount;             // encrypted transaction count
        RiskLevel riskLevel;
        SARStatus sarStatus;
        bool pepFlag;                         // politically exposed person
        bool sanctionedFlag;
        bool enhancedDueDiligence;
        uint256 lastScreenedAt;
        bool active;
    }

    struct JewelryTransaction {
        address customer;
        TransactionType txType;
        PaymentMethod paymentMethod;
        euint64 transactionValue;        // encrypted transaction amount
        euint64 gemstoneCaratWeight;     // encrypted carat weight * 100
        euint64 metalWeightGrams;        // encrypted metal weight
        euint64 appraisedValue;          // encrypted independent appraisal
        euint32 certificateNumber;       // encrypted gem certificate number
        RiskLevel riskAtTimeOfTx;
        SARStatus sarFiled;
        uint256 transactedAt;
        bool reportingThresholdTriggered;
        bool beneficialOwnerDisclosed;
    }

    struct SuspiciousActivityReport {
        address subject;
        bytes32 triggeringTransaction;
        euint64 totalSuspiciousAmount;  // encrypted suspicious amount
        euint64 cumulativeExposure;     // encrypted cumulative exposure
        string narrativeHash;           // IPFS hash of encrypted narrative
        uint256 filedAt;
        bool submittedToAuthorities;
    }

    mapping(address => Customer) private customers;
    mapping(bytes32 => JewelryTransaction) private transactions;
    mapping(bytes32 => SuspiciousActivityReport) private sars;
    mapping(address => bool) public authorizedCompliance;

    euint64 private _cashReportingThreshold;    // encrypted cash reporting threshold
    euint64 private _sarFilingThreshold;         // encrypted SAR filing threshold
    euint64 private _totalHighRiskVolume;        // encrypted total high-risk transaction volume
    euint64 private _totalSARAmount;             // encrypted total SAR amounts filed

    event CustomerOnboarded(address indexed customer, RiskLevel riskLevel);
    event TransactionRecorded(bytes32 indexed txId, RiskLevel risk);
    event ThresholdTriggered(address indexed customer, bytes32 indexed txId);
    event SARFiled(bytes32 indexed sarId, address indexed subject);
    event CustomerRiskEscalated(address indexed customer, RiskLevel newRisk);
    event EDDRequired(address indexed customer);

    constructor(
        externalEuint64 encCashThreshold, bytes memory ctProof,
        externalEuint64 encSARThreshold, bytes memory stProof
    ) Ownable(msg.sender) {
        _cashReportingThreshold = FHE.fromExternal(encCashThreshold, ctProof);
        _sarFilingThreshold = FHE.fromExternal(encSARThreshold, stProof);
        _totalHighRiskVolume = FHE.asEuint64(0);
        _totalSARAmount = FHE.asEuint64(0);
        FHE.allowThis(_cashReportingThreshold);
        FHE.allowThis(_sarFilingThreshold);
        FHE.allowThis(_totalHighRiskVolume);
        FHE.allowThis(_totalSARAmount);
    }

    modifier onlyCompliance() {
        require(authorizedCompliance[msg.sender] || msg.sender == owner(), "Not compliance officer");
        _;
    }

    function grantComplianceAccess(address officer) external onlyOwner {
        authorizedCompliance[officer] = true;
    }

    function onboardCustomer(
        address customer,
        RiskLevel initialRisk,
        bool isPEP,
        externalEuint64 encInitialRiskScore, bytes calldata rsProof
    ) external onlyCompliance {
        euint64 riskScore = FHE.fromExternal(encInitialRiskScore, rsProof);
        customers[customer] = Customer({
            totalTransactionValue30Days: FHE.asEuint64(0),
            totalTransactionValue12Months: FHE.asEuint64(0),
            riskScore: riskScore,
            cashTransactionTotal: FHE.asEuint64(0),
            transactionCount: FHE.asEuint32(0),
            riskLevel: initialRisk,
            sarStatus: SARStatus.NONE,
            pepFlag: isPEP,
            sanctionedFlag: false,
            enhancedDueDiligence: isPEP || initialRisk >= RiskLevel.HIGH,
            lastScreenedAt: block.timestamp,
            active: true
        });

        FHE.allowThis(riskScore);
        FHE.allow(riskScore, msg.sender);
        FHE.allowThis(customers[customer].totalTransactionValue30Days);
        FHE.allow(customers[customer].totalTransactionValue30Days, msg.sender);
        FHE.allowThis(customers[customer].totalTransactionValue12Months);
        FHE.allow(customers[customer].totalTransactionValue12Months, msg.sender);
        FHE.allowThis(customers[customer].cashTransactionTotal);
        FHE.allow(customers[customer].cashTransactionTotal, msg.sender);
        FHE.allowThis(customers[customer].transactionCount);
        FHE.allow(customers[customer].transactionCount, msg.sender);

        if (isPEP || initialRisk >= RiskLevel.HIGH) {
            emit EDDRequired(customer);
        }
        emit CustomerOnboarded(customer, initialRisk);
    }

    function recordTransaction(
        address customer,
        TransactionType txType,
        PaymentMethod paymentMethod,
        externalEuint64 encTxValue, bytes calldata tvProof,
        externalEuint64 encAppraisedValue, bytes calldata avProof,
        externalEuint64 encCaratWeight, bytes calldata cwProof,
        bool beneficialOwnerDisclosed
    ) external onlyCompliance nonReentrant returns (bytes32 txId) {
        Customer storage cust = customers[customer];
        require(cust.active && !cust.sanctionedFlag, "Customer blocked");

        euint64 txValue = FHE.fromExternal(encTxValue, tvProof);
        euint64 appraisedValue = FHE.fromExternal(encAppraisedValue, avProof);
        euint64 caratWeight = FHE.fromExternal(encCaratWeight, cwProof);

        cust.totalTransactionValue30Days = FHE.add(cust.totalTransactionValue30Days, txValue);
        cust.totalTransactionValue12Months = FHE.add(cust.totalTransactionValue12Months, txValue);
        cust.transactionCount = FHE.add(cust.transactionCount, FHE.asEuint32(1));

        if (paymentMethod == PaymentMethod.CASH || paymentMethod == PaymentMethod.MIXED) {
            cust.cashTransactionTotal = FHE.add(cust.cashTransactionTotal, txValue);
            FHE.allowThis(cust.cashTransactionTotal);
        }

        txId = keccak256(abi.encodePacked(customer, block.timestamp, txType));

        bool thresholdTriggered = cust.riskLevel >= RiskLevel.HIGH;

        transactions[txId] = JewelryTransaction({
            customer: customer,
            txType: txType,
            paymentMethod: paymentMethod,
            transactionValue: txValue,
            gemstoneCaratWeight: caratWeight,
            metalWeightGrams: FHE.asEuint64(0),
            appraisedValue: appraisedValue,
            certificateNumber: FHE.asEuint32(0),
            riskAtTimeOfTx: cust.riskLevel,
            sarFiled: SARStatus.NONE,
            transactedAt: block.timestamp,
            reportingThresholdTriggered: thresholdTriggered,
            beneficialOwnerDisclosed: beneficialOwnerDisclosed
        });

        FHE.allowThis(txValue); FHE.allow(txValue, msg.sender);
        FHE.allowThis(appraisedValue); FHE.allow(appraisedValue, msg.sender);
        FHE.allowThis(caratWeight); FHE.allow(caratWeight, msg.sender);
        FHE.allowThis(transactions[txId].metalWeightGrams);
        FHE.allowThis(transactions[txId].certificateNumber);
        FHE.allowThis(cust.totalTransactionValue30Days);
        FHE.allow(cust.totalTransactionValue30Days, msg.sender);
        FHE.allowThis(cust.totalTransactionValue12Months);
        FHE.allow(cust.totalTransactionValue12Months, msg.sender);
        FHE.allowThis(cust.transactionCount);

        if (thresholdTriggered) {
            _totalHighRiskVolume = FHE.add(_totalHighRiskVolume, txValue);
            FHE.allowThis(_totalHighRiskVolume);
            emit ThresholdTriggered(customer, txId);
        }

        emit TransactionRecorded(txId, cust.riskLevel);
    }

    function fileSAR(
        address subject,
        bytes32 triggeringTx,
        externalEuint64 encSuspiciousAmount, bytes calldata saProof,
        string calldata narrativeIPFSHash
    ) external onlyCompliance returns (bytes32 sarId) {
        euint64 suspiciousAmount = FHE.fromExternal(encSuspiciousAmount, saProof);
        sarId = keccak256(abi.encodePacked(subject, triggeringTx, block.timestamp));

        customers[subject].sarStatus = SARStatus.FILED;
        transactions[triggeringTx].sarFiled = SARStatus.FILED;

        sars[sarId] = SuspiciousActivityReport({
            subject: subject,
            triggeringTransaction: triggeringTx,
            totalSuspiciousAmount: suspiciousAmount,
            cumulativeExposure: customers[subject].totalTransactionValue12Months,
            narrativeHash: narrativeIPFSHash,
            filedAt: block.timestamp,
            submittedToAuthorities: false
        });

        _totalSARAmount = FHE.add(_totalSARAmount, suspiciousAmount);
        FHE.allowThis(suspiciousAmount);
        FHE.allow(suspiciousAmount, msg.sender);
        FHE.allowThis(sars[sarId].cumulativeExposure);
        FHE.allow(sars[sarId].cumulativeExposure, msg.sender);
        FHE.allowThis(_totalSARAmount);
        emit SARFiled(sarId, subject);
    }

    function escalateCustomerRisk(address customer, RiskLevel newRisk) external onlyCompliance {
        customers[customer].riskLevel = newRisk;
        if (newRisk == RiskLevel.SANCTIONED) {
            customers[customer].sanctionedFlag = true;
        }
        if (newRisk >= RiskLevel.HIGH) {
            customers[customer].enhancedDueDiligence = true;
        }
        emit CustomerRiskEscalated(customer, newRisk);
    }

    function allowCustomerDataView(address customer, address viewer) external onlyCompliance {
        Customer storage cust = customers[customer];
        FHE.allow(cust.totalTransactionValue30Days, viewer);
        FHE.allow(cust.totalTransactionValue12Months, viewer);
        FHE.allow(cust.riskScore, viewer);
        FHE.allow(cust.cashTransactionTotal, viewer);
    }

    function allowAggregateStats(address regulator) external onlyOwner {
        FHE.allow(_totalHighRiskVolume, regulator);
        FHE.allow(_totalSARAmount, regulator);
    }
}
