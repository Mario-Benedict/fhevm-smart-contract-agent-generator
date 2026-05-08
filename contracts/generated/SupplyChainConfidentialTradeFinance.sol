// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SupplyChainConfidentialTradeFinance
/// @notice Trade finance platform with encrypted invoice values and buyer credit limits.
///         Factors can purchase receivables without knowing the exact invoice amounts
///         from competing factors.
contract SupplyChainConfidentialTradeFinance is ZamaEthereumConfig, Ownable {
    enum InvoiceStatus { Pending, Financed, Paid, Defaulted }

    struct Invoice {
        address seller;
        address buyer;
        euint64 invoiceAmount;
        euint64 financedAmount;
        euint8 buyerCreditScore; // encrypted
        uint256 dueDate;
        InvoiceStatus status;
        address factor;
    }

    struct FactorPosition {
        euint64 availableCapital;
        euint64 deployedCapital;
        euint8 riskTolerance;    // encrypted: 1-5 (5=high risk tolerance)
        bool active;
    }

    mapping(uint256 => Invoice) private invoices;
    uint256 public invoiceCount;
    mapping(address => FactorPosition) private factors;
    mapping(address => bool) public isFactor;
    euint64 private _totalInvoiceVolume;
    euint64 private _totalDefaulted;

    event InvoiceSubmitted(uint256 indexed id, address seller);
    event InvoiceFinanced(uint256 indexed id, address factor);
    event InvoicePaid(uint256 indexed id);
    event InvoiceDefaulted(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _totalInvoiceVolume = FHE.asEuint64(0);
        _totalDefaulted = FHE.asEuint64(0);
        FHE.allowThis(_totalInvoiceVolume);
        FHE.allowThis(_totalDefaulted);
    }

    function registerFactor(
        address f,
        externalEuint64 encCapital, bytes calldata cProof,
        externalEuint8 encRisk, bytes calldata rProof
    ) external onlyOwner {
        isFactor[f] = true;
        factors[f].availableCapital = FHE.fromExternal(encCapital, cProof);
        factors[f].riskTolerance = FHE.fromExternal(encRisk, rProof);
        factors[f].deployedCapital = FHE.asEuint64(0);
        factors[f].active = true;
        FHE.allowThis(factors[f].availableCapital);
        FHE.allow(factors[f].availableCapital, f);
        FHE.allowThis(factors[f].riskTolerance);
        FHE.allowThis(factors[f].deployedCapital);
        FHE.allow(factors[f].deployedCapital, f);
    }

    function submitInvoice(
        address buyer, uint256 dueDate,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint8 encBuyerScore, bytes calldata bProof
    ) external returns (uint256 id) {
        id = invoiceCount++;
        invoices[id].seller = msg.sender;
        invoices[id].buyer = buyer;
        invoices[id].invoiceAmount = FHE.fromExternal(encAmount, aProof);
        invoices[id].buyerCreditScore = FHE.fromExternal(encBuyerScore, bProof);
        invoices[id].financedAmount = FHE.asEuint64(0);
        invoices[id].dueDate = dueDate;
        invoices[id].status = InvoiceStatus.Pending;
        _totalInvoiceVolume = FHE.add(_totalInvoiceVolume, invoices[id].invoiceAmount);
        FHE.allowThis(invoices[id].invoiceAmount);
        FHE.allow(invoices[id].invoiceAmount, msg.sender);
        FHE.allowThis(invoices[id].buyerCreditScore);
        FHE.allowThis(invoices[id].financedAmount);
        FHE.allowThis(_totalInvoiceVolume);
        emit InvoiceSubmitted(id, msg.sender);
    }

    function financeInvoice(
        uint256 invoiceId,
        externalEuint64 encAdvance, bytes calldata proof
    ) external {
        require(isFactor[msg.sender] && factors[msg.sender].active, "Not factor");
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Pending, "Not available");
        euint64 advance = FHE.fromExternal(encAdvance, proof);
        FactorPosition storage fp = factors[msg.sender];
        ebool hasCapital = FHE.ge(fp.availableCapital, advance);
        ebool creditOk = FHE.ge(inv.buyerCreditScore, fp.riskTolerance);
        ebool canFinance = FHE.and(hasCapital, creditOk);
        euint64 actual = FHE.select(canFinance, advance, FHE.asEuint64(0));
        inv.financedAmount = actual;
        inv.factor = msg.sender;
        fp.availableCapital = FHE.sub(fp.availableCapital, actual);
        fp.deployedCapital = FHE.add(fp.deployedCapital, actual);
        if (FHE.isInitialized(canFinance)) inv.status = InvoiceStatus.Financed;
        FHE.allowThis(inv.financedAmount);
        FHE.allow(inv.financedAmount, inv.seller);
        FHE.allow(inv.financedAmount, msg.sender);
        FHE.allowThis(fp.availableCapital);
        FHE.allow(fp.availableCapital, msg.sender);
        FHE.allowThis(fp.deployedCapital);
        FHE.allow(fp.deployedCapital, msg.sender);
        emit InvoiceFinanced(invoiceId, msg.sender);
    }

    function settleInvoice(uint256 invoiceId) external onlyOwner {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Financed, "Not financed");
        inv.status = InvoiceStatus.Paid;
        if (inv.factor != address(0)) {
            factors[inv.factor].deployedCapital = FHE.sub(factors[inv.factor].deployedCapital, inv.financedAmount);
            factors[inv.factor].availableCapital = FHE.add(factors[inv.factor].availableCapital, inv.financedAmount);
            FHE.allowThis(factors[inv.factor].deployedCapital);
            FHE.allowThis(factors[inv.factor].availableCapital);
        }
        emit InvoicePaid(invoiceId);
    }

    function defaultInvoice(uint256 invoiceId) external onlyOwner {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Financed && block.timestamp > inv.dueDate, "Cannot default");
        inv.status = InvoiceStatus.Defaulted;
        _totalDefaulted = FHE.add(_totalDefaulted, inv.financedAmount);
        FHE.allowThis(_totalDefaulted);
        emit InvoiceDefaulted(invoiceId);
    }
}
