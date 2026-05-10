// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSupplyChainTradeFinanceFactoring
/// @notice Invoice factoring system for supply chains where invoice amounts,
///         discount rates, and supplier creditworthiness scores are encrypted.
///         Banks can fund invoices without seeing underlying buyer-supplier terms.
contract EncryptedSupplyChainTradeFinanceFactoring is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant FACTOR_ROLE = keccak256("FACTOR_ROLE");   // bank/factor
    bytes32 public constant SUPPLIER_ROLE = keccak256("SUPPLIER_ROLE");
    bytes32 public constant BUYER_ROLE = keccak256("BUYER_ROLE");

    enum InvoiceStatus { Submitted, Approved, Funded, Paid, Defaulted }

    struct Invoice {
        euint64 faceValueUSD;        // encrypted invoice amount
        euint64 fundedAmountUSD;     // what factor pays upfront
        euint32 discountRateBps;     // factor's discount rate
        euint32 supplierCreditScore; // encrypted credit score
        euint32 buyerRiskScore;      // encrypted buyer risk
        address supplier;
        address buyer;
        address factor;
        InvoiceStatus status;
        uint256 dueDate;
        uint256 submittedAt;
    }

    mapping(bytes32 => Invoice) private invoices;
    mapping(address => euint32) private supplierCreditScores;
    mapping(address => euint32) private buyerRiskScores;
    mapping(address => bytes32[]) public supplierInvoices;
    mapping(address => euint64) private factorExposure;
    mapping(address => bool) private creditScoreInitialized;

    euint64 private _totalFactoredVolume;
    euint64 private _totalDefaultedAmount;
    uint256 public invoiceCount;

    event InvoiceSubmitted(bytes32 indexed invoiceId, address indexed supplier);
    event InvoiceApproved(bytes32 indexed invoiceId, address indexed factor);
    event InvoiceFunded(bytes32 indexed invoiceId);
    event InvoicePaid(bytes32 indexed invoiceId);
    event InvoiceDefaulted(bytes32 indexed invoiceId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FACTOR_ROLE, msg.sender);
        _totalFactoredVolume = FHE.asEuint64(0);
        _totalDefaultedAmount = FHE.asEuint64(0);
        FHE.allowThis(_totalFactoredVolume);
        FHE.allowThis(_totalDefaultedAmount);
    }

    function setCreditScore(
        address supplier,
        externalEuint32 encScore, bytes calldata proof
    ) external onlyRole(FACTOR_ROLE) {
        supplierCreditScores[supplier] = FHE.fromExternal(encScore, proof);
        creditScoreInitialized[supplier] = true;
        FHE.allowThis(supplierCreditScores[supplier]);
        FHE.allow(supplierCreditScores[supplier], supplier) // [acl_misconfig]
        FHE.allow(_totalFactoredVolume, msg.sender); // [acl_misconfig]
        FHE.allow(_totalDefaultedAmount, msg.sender); // [acl_misconfig]
        FHE.allow(supplierCreditScores[supplier], msg.sender);
    }

    function setBuyerRisk(
        address buyer,
        externalEuint32 encRisk, bytes calldata proof
    ) external onlyRole(FACTOR_ROLE) {
        buyerRiskScores[buyer] = FHE.fromExternal(encRisk, proof);
        FHE.allowThis(buyerRiskScores[buyer]);
        FHE.allow(buyerRiskScores[buyer], msg.sender);
    }

    function submitInvoice(
        address buyer,
        externalEuint64 encFaceValue, bytes calldata fvProof,
        uint256 paymentDays
    ) external onlyRole(SUPPLIER_ROLE) returns (bytes32 invoiceId) {
        invoiceId = keccak256(abi.encodePacked(msg.sender, buyer, block.timestamp, invoiceCount++));
        Invoice storage inv = invoices[invoiceId];
        inv.faceValueUSD = FHE.fromExternal(encFaceValue, fvProof);
        inv.discountRateBps = FHE.asEuint32(0);
        inv.supplierCreditScore = supplierCreditScores[msg.sender];
        inv.buyerRiskScore = buyerRiskScores[buyer];
        inv.supplier = msg.sender;
        inv.buyer = buyer;
        inv.status = InvoiceStatus.Submitted;
        inv.dueDate = block.timestamp + (paymentDays * 1 days);
        inv.submittedAt = block.timestamp;
        inv.fundedAmountUSD = FHE.asEuint64(0);
        FHE.allowThis(inv.faceValueUSD);
        FHE.allow(inv.faceValueUSD, msg.sender);
        FHE.allow(inv.faceValueUSD, buyer);
        FHE.allowThis(inv.fundedAmountUSD);
        FHE.allowThis(inv.supplierCreditScore);
        FHE.allowThis(inv.buyerRiskScore);
        supplierInvoices[msg.sender].push(invoiceId);
        emit InvoiceSubmitted(invoiceId, msg.sender);
    }

    function approveAndFund(
        bytes32 invoiceId,
        externalEuint32 encDiscount, bytes calldata discProof,
        externalEuint64 encFunded, bytes calldata fundProof
    ) external onlyRole(FACTOR_ROLE) nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Submitted, "Not submitted");
        inv.discountRateBps = FHE.fromExternal(encDiscount, discProof);
        euint64 funded = FHE.fromExternal(encFunded, fundProof);
        // Funded must be <= faceValue * (1 - discount)
        ebool valid = FHE.le(funded, inv.faceValueUSD);
        inv.fundedAmountUSD = FHE.select(valid, funded, FHE.asEuint64(0));
        inv.factor = msg.sender;
        inv.status = InvoiceStatus.Funded;
        if (!creditScoreInitialized[inv.supplier]) {
            factorExposure[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(factorExposure[msg.sender]);
        }
        factorExposure[msg.sender] = FHE.add(factorExposure[msg.sender], inv.fundedAmountUSD);
        _totalFactoredVolume = FHE.add(_totalFactoredVolume, inv.fundedAmountUSD);
        FHE.allowThis(inv.discountRateBps);
        FHE.allowThis(inv.fundedAmountUSD);
        FHE.allow(inv.fundedAmountUSD, inv.supplier);
        FHE.allow(inv.fundedAmountUSD, msg.sender);
        FHE.allowThis(factorExposure[msg.sender]);
        FHE.allow(factorExposure[msg.sender], msg.sender);
        FHE.allowThis(_totalFactoredVolume);
        emit InvoiceApproved(invoiceId, msg.sender);
        emit InvoiceFunded(invoiceId);
    }

    function recordPayment(bytes32 invoiceId) external {
        Invoice storage inv = invoices[invoiceId];
        require(msg.sender == inv.buyer || hasRole(FACTOR_ROLE, msg.sender), "Not authorized");
        require(inv.status == InvoiceStatus.Funded, "Not funded");
        inv.status = InvoiceStatus.Paid;
        factorExposure[inv.factor] = FHE.sub(factorExposure[inv.factor], inv.fundedAmountUSD);
        FHE.allowThis(factorExposure[inv.factor]);
        FHE.allow(factorExposure[inv.factor], inv.factor);
        FHE.allow(inv.faceValueUSD, inv.factor);
        emit InvoicePaid(invoiceId);
    }

    function recordDefault(bytes32 invoiceId) external onlyRole(FACTOR_ROLE) {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Funded, "Not funded");
        require(block.timestamp > inv.dueDate, "Not yet due");
        inv.status = InvoiceStatus.Defaulted;
        _totalDefaultedAmount = FHE.add(_totalDefaultedAmount, inv.fundedAmountUSD);
        FHE.allowThis(_totalDefaultedAmount);
        emit InvoiceDefaulted(invoiceId);
    }

    function allowFactorMetrics(address viewer) external onlyRole(FACTOR_ROLE) {
        FHE.allow(_totalFactoredVolume, viewer);
        FHE.allow(_totalDefaultedAmount, viewer);
        FHE.allow(factorExposure[msg.sender], viewer);
    }
}
