// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateSupplyChainFinanceFactoring
/// @notice Supply chain invoice factoring: encrypted invoice values, encrypted advance rates,
///         encrypted supplier credit scores, and confidential early payment discount dynamics.
contract PrivateSupplyChainFinanceFactoring is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Invoice {
        address supplier;
        address buyer;
        euint64 invoiceAmountUSD;    // encrypted face value
        euint64 advanceRateBps;      // encrypted advance rate (e.g. 9000 = 90%)
        euint64 advanceAmountUSD;    // encrypted funds advanced
        euint64 discountRateBps;     // encrypted discount for early payment
        euint64 factorFeeUSD;        // encrypted factoring fee
        euint64 supplierCreditScore; // encrypted credit score
        uint256 invoiceDueDate;
        uint256 advancedAt;
        bool funded;
        bool repaid;
        bool disputed;
    }

    struct BuyerProfile {
        euint64 paymentHistoryScore; // encrypted payment history 0-1000
        euint64 approvedCreditLine;  // encrypted approved credit line
        euint64 usedCreditLine;      // encrypted used credit
        bool approved;
    }

    mapping(uint256 => Invoice) private invoices;
    mapping(address => BuyerProfile) private buyers;
    uint256 public invoiceCount;
    euint64 private _totalAdvancedUSD;
    euint64 private _totalFactorFees;
    mapping(address => bool) public isFactor;

    event InvoiceSubmitted(uint256 indexed id, address supplier, address buyer);
    event InvoiceFunded(uint256 indexed id);
    event InvoiceRepaid(uint256 indexed id);
    event InvoiceDisputed(uint256 indexed id);
    event BuyerApproved(address indexed buyer);

    constructor() Ownable(msg.sender) {
        _totalAdvancedUSD = FHE.asEuint64(0);
        _totalFactorFees = FHE.asEuint64(0);
        FHE.allowThis(_totalAdvancedUSD);
        FHE.allowThis(_totalFactorFees);
        isFactor[msg.sender] = true;
    }

    function addFactor(address f) external onlyOwner { isFactor[f] = true; }

    function approveBuyer(
        address buyer,
        externalEuint64 encScore, bytes calldata sProof,
        externalEuint64 encCreditLine, bytes calldata clProof
    ) external {
        require(isFactor[msg.sender], "Not factor");
        euint64 score = FHE.fromExternal(encScore, sProof);
        euint64 creditLine = FHE.fromExternal(encCreditLine, clProof);
        buyers[buyer] = BuyerProfile({
            paymentHistoryScore: score, approvedCreditLine: creditLine,
            usedCreditLine: FHE.asEuint64(0), approved: true
        });
        FHE.allowThis(buyers[buyer].paymentHistoryScore);
        FHE.allowThis(buyers[buyer].approvedCreditLine);
        FHE.allowThis(buyers[buyer].usedCreditLine);
        FHE.allow(buyers[buyer].approvedCreditLine, buyer); // [acl_misconfig]
        FHE.allow(_totalAdvancedUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalFactorFees, msg.sender); // [acl_misconfig]
        FHE.allow(buyers[buyer].usedCreditLine, buyer);
        emit BuyerApproved(buyer);
    }

    function submitInvoice(
        address buyer, uint256 dueDate,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint64 encCreditScore, bytes calldata csProof
    ) external returns (uint256 id) {
        require(buyers[buyer].approved, "Buyer not approved");
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint64 creditScore = FHE.fromExternal(encCreditScore, csProof);
        // Advance rate based on credit score: >800 => 95%, >600 => 85%, else 75%
        ebool highCredit = FHE.ge(creditScore, FHE.asEuint64(800));
        ebool medCredit = FHE.ge(creditScore, FHE.asEuint64(600));
        euint64 advanceRate = FHE.select(highCredit, FHE.asEuint64(9500),
            FHE.select(medCredit, FHE.asEuint64(8500), FHE.asEuint64(7500)));
        euint64 advance = FHE.div(FHE.mul(amount, advanceRate), 10000);
        euint64 factorFee = FHE.sub(amount, advance);
        id = invoiceCount++;
        Invoice storage _s0 = invoices[id];
        _s0.supplier = msg.sender;
        _s0.buyer = buyer;
        _s0.invoiceAmountUSD = amount;
        _s0.advanceRateBps = advanceRate;
        _s0.advanceAmountUSD = advance;
        _s0.discountRateBps = FHE.asEuint64(200);
        _s0.factorFeeUSD = factorFee;
        _s0.supplierCreditScore = creditScore;
        _s0.invoiceDueDate = dueDate;
        _s0.advancedAt = 0;
        _s0.funded = false;
        _s0.repaid = false;
        _s0.disputed = false;
        FHE.allowThis(invoices[id].invoiceAmountUSD);
        FHE.allowThis(invoices[id].advanceRateBps);
        FHE.allowThis(invoices[id].advanceAmountUSD);
        FHE.allowThis(invoices[id].factorFeeUSD);
        FHE.allowThis(invoices[id].supplierCreditScore);
        FHE.allow(invoices[id].advanceAmountUSD, msg.sender);
        FHE.allow(invoices[id].factorFeeUSD, msg.sender);
        emit InvoiceSubmitted(id, msg.sender, buyer);
    }

    function fundInvoice(uint256 invoiceId) external nonReentrant {
        require(isFactor[msg.sender], "Not factor");
        Invoice storage inv = invoices[invoiceId];
        require(!inv.funded && !inv.disputed, "Not fundable");
        require(buyers[inv.buyer].approved, "Buyer not approved");
        // Check buyer credit line
        BuyerProfile storage buyer = buyers[inv.buyer];
        ebool withinLimit = FHE.le(FHE.add(buyer.usedCreditLine, inv.invoiceAmountUSD), buyer.approvedCreditLine);
        euint64 actual = FHE.select(withinLimit, inv.advanceAmountUSD, FHE.asEuint64(0));
        buyer.usedCreditLine = FHE.add(buyer.usedCreditLine, inv.invoiceAmountUSD);
        inv.funded = true;
        inv.advancedAt = block.timestamp;
        _totalAdvancedUSD = FHE.add(_totalAdvancedUSD, actual);
        _totalFactorFees = FHE.add(_totalFactorFees, inv.factorFeeUSD);
        FHE.allowThis(buyer.usedCreditLine);
        FHE.allow(buyer.usedCreditLine, inv.buyer);
        FHE.allow(actual, inv.supplier);
        FHE.allowThis(_totalAdvancedUSD);
        FHE.allowThis(_totalFactorFees);
        emit InvoiceFunded(invoiceId);
    }

    function repayInvoice(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        require(msg.sender == inv.buyer && inv.funded && !inv.repaid, "Not repayable");
        inv.repaid = true;
        buyers[inv.buyer].usedCreditLine = FHE.sub(buyers[inv.buyer].usedCreditLine, inv.invoiceAmountUSD);
        FHE.allowThis(buyers[inv.buyer].usedCreditLine);
        emit InvoiceRepaid(invoiceId);
    }

    function disputeInvoice(uint256 invoiceId) external {
        Invoice storage inv = invoices[invoiceId];
        require(msg.sender == inv.buyer || msg.sender == inv.supplier, "Not party");
        inv.disputed = true;
        emit InvoiceDisputed(invoiceId);
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