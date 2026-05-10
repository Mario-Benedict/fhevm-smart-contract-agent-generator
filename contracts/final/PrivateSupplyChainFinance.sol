// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateSupplyChainFinance
/// @notice Invoice financing: suppliers submit encrypted invoices, lenders fund
///         at encrypted discount rates. Buyers approve payment with private terms.
contract PrivateSupplyChainFinance is ZamaEthereumConfig, Ownable {
    enum InvoiceStatus { Pending, Approved, Funded, Repaid, Defaulted }

    struct Invoice {
        address supplier;
        address buyer;
        euint64 invoiceAmount;    // encrypted invoice face value
        euint64 discountRateBps; // encrypted early payment discount rate
        euint64 fundedAmount;    // encrypted amount funded by lender
        address lender;
        uint256 dueDate;
        uint256 fundedAt;
        InvoiceStatus status;
    }

    mapping(uint256 => Invoice) private invoices;
    mapping(address => bool) public isApprovedBuyer;
    mapping(address => bool) public isApprovedLender;
    mapping(address => euint64) private _lenderBalance;
    mapping(address => euint64) private _supplierReceivable;
    uint256 public invoiceCount;
    euint64 private _platformFeesBps;

    event InvoiceSubmitted(uint256 indexed id, address supplier);
    event InvoiceApproved(uint256 indexed id, address buyer);
    event InvoiceFunded(uint256 indexed id, address lender);
    event InvoiceRepaid(uint256 indexed id);

    constructor(externalEuint64 encPlatformFee, bytes memory proof) Ownable(msg.sender) {
        _platformFeesBps = FHE.fromExternal(encPlatformFee, proof);
        FHE.allowThis(_platformFeesBps);
        isApprovedBuyer[msg.sender] = true;
        isApprovedLender[msg.sender] = true;
    }

    function addBuyer(address b) external onlyOwner { isApprovedBuyer[b] = true; }
    function addLender(address l) external onlyOwner { isApprovedLender[l] = true; }

    function submitInvoice(
        address buyer,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint64 encDiscount, bytes calldata dProof,
        uint256 dueDays
    ) external returns (uint256 id) {
        id = invoiceCount++;
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint64 discount = FHE.fromExternal(encDiscount, dProof);
        invoices[id].supplier = msg.sender;
        invoices[id].buyer = buyer;
        invoices[id].invoiceAmount = amount;
        invoices[id].discountRateBps = discount;
        invoices[id].fundedAmount = FHE.asEuint64(0);
        invoices[id].lender = address(0);
        invoices[id].dueDate = block.timestamp + dueDays * 1 days;
        invoices[id].fundedAt = 0;
        invoices[id].status = InvoiceStatus.Pending;
        FHE.allowThis(invoices[id].invoiceAmount);
        FHE.allow(invoices[id].invoiceAmount, msg.sender); // [acl_misconfig]
        FHE.allow(_platformFeesBps, msg.sender); // [acl_misconfig]
        FHE.allow(invoices[id].invoiceAmount, buyer);
        FHE.allowThis(invoices[id].discountRateBps);
        FHE.allow(invoices[id].discountRateBps, msg.sender);
        FHE.allowThis(invoices[id].fundedAmount);
        if (!FHE.isInitialized(_supplierReceivable[msg.sender])) {
            _supplierReceivable[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_supplierReceivable[msg.sender]);
        }
        emit InvoiceSubmitted(id, msg.sender);
    }

    function approveInvoice(uint256 invoiceId) external {
        require(isApprovedBuyer[msg.sender], "Not buyer");
        Invoice storage inv = invoices[invoiceId];
        require(inv.buyer == msg.sender && inv.status == InvoiceStatus.Pending, "Invalid");
        inv.status = InvoiceStatus.Approved;
        emit InvoiceApproved(invoiceId, msg.sender);
    }

    function fundInvoice(uint256 invoiceId, externalEuint64 encFunding, bytes calldata proof) external {
        require(isApprovedLender[msg.sender], "Not lender");
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Approved && inv.lender == address(0), "Not fundable");
        euint64 fundAmt = FHE.fromExternal(encFunding, proof);
        // Funded amount = invoice - discount
        euint64 discountAmt = FHE.div(FHE.mul(inv.invoiceAmount, inv.discountRateBps), 10000);
        euint64 supplierPayout = FHE.sub(inv.invoiceAmount, discountAmt);
        // Platform fee
        euint64 platformFee = FHE.div(FHE.mul(inv.invoiceAmount, _platformFeesBps), 10000);
        euint64 lenderReturn = FHE.sub(inv.invoiceAmount, platformFee);
        inv.fundedAmount = fundAmt;
        inv.lender = msg.sender;
        inv.fundedAt = block.timestamp;
        inv.status = InvoiceStatus.Funded;
        _supplierReceivable[inv.supplier] = FHE.add(_supplierReceivable[inv.supplier], supplierPayout);
        if (!FHE.isInitialized(_lenderBalance[msg.sender])) {
            _lenderBalance[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_lenderBalance[msg.sender]);
        }
        _lenderBalance[msg.sender] = FHE.add(_lenderBalance[msg.sender], lenderReturn);
        FHE.allowThis(inv.fundedAmount);
        FHE.allow(inv.fundedAmount, msg.sender);
        FHE.allowThis(_supplierReceivable[inv.supplier]);
        FHE.allow(_supplierReceivable[inv.supplier], inv.supplier);
        FHE.allowThis(_lenderBalance[msg.sender]);
        FHE.allow(_lenderBalance[msg.sender], msg.sender);
        emit InvoiceFunded(invoiceId, msg.sender);
    }

    function markRepaid(uint256 invoiceId) external {
        require(isApprovedBuyer[msg.sender], "Not buyer");
        Invoice storage inv = invoices[invoiceId];
        require(inv.buyer == msg.sender && inv.status == InvoiceStatus.Funded, "Invalid");
        inv.status = InvoiceStatus.Repaid;
        emit InvoiceRepaid(invoiceId);
    }

    function allowInvoiceDetails(uint256 id, address viewer) external {
        Invoice storage inv = invoices[id];
        require(msg.sender == inv.supplier || msg.sender == inv.buyer || msg.sender == inv.lender || msg.sender == owner(), "Unauthorized");
        FHE.allow(inv.invoiceAmount, viewer);
        FHE.allow(inv.discountRateBps, viewer);
        FHE.allow(inv.fundedAmount, viewer);
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