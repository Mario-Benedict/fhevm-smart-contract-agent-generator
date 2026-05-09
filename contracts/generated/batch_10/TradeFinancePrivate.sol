// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TradeFinancePrivate
/// @notice Confidential trade finance: exporters issue private invoices, banks
///         finance them with encrypted loan amounts and discount rates.
contract TradeFinancePrivate is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum InvoiceStatus { Issued, Financed, Paid, Defaulted }

    struct Invoice {
        address exporter;
        address importer;
        address financingBank;
        string goodsDescription;
        euint64 invoiceAmount;
        euint64 discountRate;    // basis points encrypted
        euint64 financedAmount;  // amount advanced by bank
        euint64 repaidAmount;
        uint256 dueDate;
        InvoiceStatus status;
    }

    mapping(uint256 => Invoice) private invoices;
    mapping(address => euint64) private _bankReserves;
    mapping(address => euint64) private _exporterBalances;
    mapping(address => bool) public isBank;
    uint256 public nextInvoiceId;
    euint64 private _totalFinanced;

    event InvoiceIssued(uint256 indexed id, address exporter);
    event InvoiceFinanced(uint256 indexed id, address bank);
    event InvoiceRepaid(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _totalFinanced = FHE.asEuint64(0);
        FHE.allowThis(_totalFinanced);
        isBank[msg.sender] = true;
    }

    function registerBank(address bank) external onlyOwner { isBank[bank] = true; }

    function depositBankReserves(externalEuint64 encAmount, bytes calldata proof) external {
        require(isBank[msg.sender], "Not a bank");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _bankReserves[msg.sender] = FHE.add(_bankReserves[msg.sender], amount);
        FHE.allowThis(_bankReserves[msg.sender]);
        FHE.allow(_bankReserves[msg.sender], msg.sender);
    }

    function issueInvoice(
        address importer,
        string calldata goods,
        externalEuint64 encAmount, bytes calldata proof,
        uint256 dueDays
    ) external returns (uint256 id) {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        id = nextInvoiceId++;
        invoices[id].exporter = msg.sender;
        invoices[id].importer = importer;
        invoices[id].financingBank = address(0);
        invoices[id].goodsDescription = goods;
        invoices[id].invoiceAmount = amount;
        invoices[id].discountRate = FHE.asEuint64(0);
        invoices[id].financedAmount = FHE.asEuint64(0);
        invoices[id].repaidAmount = FHE.asEuint64(0);
        invoices[id].dueDate = block.timestamp + dueDays * 1 days;
        invoices[id].status = InvoiceStatus.Issued;
        FHE.allowThis(invoices[id].invoiceAmount);
        FHE.allow(invoices[id].invoiceAmount, importer);
        FHE.allowThis(invoices[id].discountRate);
        FHE.allowThis(invoices[id].financedAmount);
        FHE.allowThis(invoices[id].repaidAmount);
        emit InvoiceIssued(id, msg.sender);
    }

    function financeInvoice(
        uint256 invoiceId,
        externalEuint64 encRate, bytes calldata rateProof
    ) external nonReentrant {
        require(isBank[msg.sender], "Not a bank");
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Issued, "Invalid status");
        euint64 rate = FHE.fromExternal(encRate, rateProof);
        // financed = invoiceAmount - discount
        euint64 discount = FHE.div(FHE.mul(inv.invoiceAmount, rate), 10000);
        euint64 financed = FHE.sub(inv.invoiceAmount, discount);
        ebool hasFunds = FHE.ge(_bankReserves[msg.sender], financed);
        euint64 actual = FHE.select(hasFunds, financed, FHE.asEuint64(0));
        _bankReserves[msg.sender] = FHE.sub(_bankReserves[msg.sender], actual);
        _exporterBalances[inv.exporter] = FHE.add(_exporterBalances[inv.exporter], actual);
        inv.financingBank = msg.sender;
        inv.discountRate = rate;
        inv.financedAmount = actual;
        inv.status = InvoiceStatus.Financed;
        _totalFinanced = FHE.add(_totalFinanced, actual);
        FHE.allowThis(_bankReserves[msg.sender]);
        FHE.allow(_bankReserves[msg.sender], msg.sender);
        FHE.allowThis(_exporterBalances[inv.exporter]);
        FHE.allow(_exporterBalances[inv.exporter], inv.exporter);
        FHE.allowThis(inv.financedAmount);
        FHE.allow(inv.financedAmount, inv.exporter);
        FHE.allowThis(_totalFinanced);
        emit InvoiceFinanced(invoiceId, msg.sender);
    }

    function repayInvoice(uint256 invoiceId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Financed && msg.sender == inv.importer, "Invalid");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        inv.repaidAmount = FHE.add(inv.repaidAmount, amount);
        _bankReserves[inv.financingBank] = FHE.add(_bankReserves[inv.financingBank], amount);
        ebool fullyRepaid = FHE.ge(inv.repaidAmount, inv.invoiceAmount);
        if (FHE.isInitialized(fullyRepaid)) inv.status = InvoiceStatus.Paid;
        FHE.allowThis(inv.repaidAmount);
        FHE.allowThis(_bankReserves[inv.financingBank]);
        FHE.allow(_bankReserves[inv.financingBank], inv.financingBank);
        emit InvoiceRepaid(invoiceId);
    }

    function withdrawExporterBalance() external nonReentrant {
        euint64 bal = _exporterBalances[msg.sender];
        _exporterBalances[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_exporterBalances[msg.sender]);
        FHE.allow(bal, msg.sender);
    }

    function allowInvoiceDetails(uint256 invoiceId, address viewer) external {
        Invoice storage inv = invoices[invoiceId];
        require(msg.sender == inv.exporter || msg.sender == inv.importer || msg.sender == inv.financingBank, "Unauthorized");
        FHE.allow(inv.invoiceAmount, viewer);
        FHE.allow(inv.financedAmount, viewer);
    }
}
